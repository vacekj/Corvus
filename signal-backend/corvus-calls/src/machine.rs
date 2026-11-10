//! The call state machine, without any I/O: a port of signal-cli 0.14.10's
//! `org.asamk.signal.manager.helper.CallManager` (deviations are marked "Corvus:" and listed in
//! `docs/calls.md`). Every input returns the [`Action`]s the driver must carry out, in order.

use std::collections::{HashMap, VecDeque};

use presage::proto::CallMessage;
use presage::proto::call_message::{self, hangup, offer};
use serde_json::Value;

use crate::backend::{CallError, Peer};
use crate::events::{CallEvent, CallState, call_info_json, wire_call_id};
use crate::protocol::{IceServer, TunnelCommand, TunnelConfig, TunnelEvent};

/// Something the driver has to do.
#[derive(Debug, Clone, PartialEq)]
pub enum Action {
    /// Send a `callEvent` to every subscription.
    Emit(CallEvent),
    /// Start `signal-call-tunnel` for this call and write the config line.
    SpawnTunnel { call_id: u64, config: TunnelConfig },
    /// Write a command line to the call's tunnel (dropped if the tunnel is gone).
    Tunnel { call_id: u64, command: TunnelCommand },
    /// Close the tunnel's stdin, then kill it if it has not exited after a grace period.
    StopTunnel { call_id: u64 },
    /// Send a `CallMessage` to the peer through presage.
    Send { peer: Peer, message: CallMessage },
    /// Fire [`Machine::ring_timeout`] for this call after the ring timeout.
    ArmRingTimer { call_id: u64 },
}

/// `CallMessage.Hangup.Type`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HangupKind {
    Normal,
    Accepted,
    Declined,
    Busy,
    NeedPermission,
}

impl HangupKind {
    pub fn from_proto(t: Option<i32>) -> Self {
        match t.and_then(|t| hangup::Type::try_from(t).ok()) {
            Some(hangup::Type::HangupAccepted) => Self::Accepted,
            Some(hangup::Type::HangupDeclined) => Self::Declined,
            Some(hangup::Type::HangupBusy) => Self::Busy,
            Some(hangup::Type::HangupNeedPermission) => Self::NeedPermission,
            Some(hangup::Type::HangupNormal) | None => Self::Normal,
        }
    }

    fn to_proto(self) -> hangup::Type {
        match self {
            Self::Normal => hangup::Type::HangupNormal,
            Self::Accepted => hangup::Type::HangupAccepted,
            Self::Declined => hangup::Type::HangupDeclined,
            Self::Busy => hangup::Type::HangupBusy,
            Self::NeedPermission => hangup::Type::HangupNeedPermission,
        }
    }

    /// The tunnel's `hangupType` (RingRTC `HangupType` in lower case). signal-cli maps
    /// `accepted`/`declined`/`busy` with or without the suffix; anything unknown is `normal`.
    fn from_tunnel(s: &str) -> Self {
        match s {
            "accepted" | "acceptedonanotherdevice" => Self::Accepted,
            "declined" | "declinedonanotherdevice" => Self::Declined,
            "busy" | "busyonanotherdevice" => Self::Busy,
            "needpermission" => Self::NeedPermission,
            _ => Self::Normal,
        }
    }
}

/// What to do with an incoming offer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OfferDisposition {
    /// Drop it silently (signal-cli does this when nobody subscribed to call events).
    Ignore(&'static str),
    /// Another call is going on: answer busy.
    Busy,
    /// Start ringing: gather keys and TURN servers, then call [`Machine::incoming_offer`].
    Ring,
}

#[derive(Debug, Clone)]
struct Call {
    id: u64,
    state: CallState,
    peer: Peer,
    /// The remote device we talk to: the caller's device for incoming calls, the answering device
    /// for outgoing ones (unknown until the answer). `destinationDeviceId` of what we send.
    peer_device: Option<u32>,
    outgoing: bool,
    input_device: Option<String>,
    output_device: Option<String>,
    /// `acceptCall` came before the tunnel reported `Ringing`.
    accept_pending: bool,
    tunnel_ringing: bool,
    /// The tunnel already asked us to send a normal hangup for this call.
    hangup_relayed: bool,
}

const RECENTLY_ENDED: usize = 64;

pub struct Machine {
    local_device_id: u32,
    input_device_name: Option<String>,
    output_device_name: Option<String>,
    calls: HashMap<u64, Call>,
    recently_ended: VecDeque<u64>,
}

fn no_call(call_id: u64) -> CallError {
    // signal-cli prints the unsigned id here.
    CallError::new(format!("No active call with id {call_id}"))
}

impl Machine {
    /// `input_device_name`/`output_device_name` go into the tunnel config when set; signal-cli
    /// never sets them, and the tunnel then uses `signal_input`/`signal_output` on macOS.
    pub fn new(
        local_device_id: u32,
        input_device_name: Option<String>,
        output_device_name: Option<String>,
    ) -> Self {
        Self {
            local_device_id,
            input_device_name,
            output_device_name,
            calls: HashMap::new(),
            recently_ended: VecDeque::new(),
        }
    }

    pub fn has_call(&self, call_id: u64) -> bool {
        self.calls.contains_key(&call_id)
    }

    pub fn call_state(&self, call_id: u64) -> Option<CallState> {
        self.calls.get(&call_id).map(|c| c.state)
    }

    pub fn call_ids(&self) -> Vec<u64> {
        self.calls.keys().copied().collect()
    }

    fn active_call(&self) -> Option<&Call> {
        self.calls.values().find(|c| c.state != CallState::Ended)
    }

    fn event(call: &Call, reason: Option<&str>) -> CallEvent {
        CallEvent {
            call_id: call.id,
            state: call.state,
            peer: call.peer.clone(),
            is_outgoing: call.outgoing,
            input_device_name: call.input_device.clone(),
            output_device_name: call.output_device.clone(),
            reason: reason.map(str::to_owned),
        }
    }

    fn info(call: &Call) -> Value {
        call_info_json(
            call.id,
            call.state,
            call.input_device.as_deref(),
            call.output_device.as_deref(),
        )
    }

    fn config(&self, call_id: u64, is_outgoing: bool) -> TunnelConfig {
        TunnelConfig {
            call_id,
            is_outgoing,
            local_device_id: self.local_device_id,
            input_device_name: self.input_device_name.clone(),
            output_device_name: self.output_device_name.clone(),
        }
    }

    // ---- RPC methods ----

    /// `startCall`. Returns the `startCall` result. signal-cli lets a second call start while one
    /// is going on; Corvus: refused, both would fight over the same audio devices.
    pub fn start_outgoing(
        &mut self,
        call_id: u64,
        peer: Peer,
        ice_servers: Vec<IceServer>,
    ) -> Result<(Value, Vec<Action>), CallError> {
        if self.active_call().is_some() {
            return Err(CallError::new("A call is already in progress"));
        }
        if self.calls.contains_key(&call_id) {
            return Err(CallError::new("Call id collision, try again"));
        }
        let call = Call {
            id: call_id,
            state: CallState::RingingOutgoing,
            peer: peer.clone(),
            peer_device: None,
            outgoing: true,
            input_device: None,
            output_device: None,
            accept_pending: false,
            tunnel_ringing: false,
            hangup_relayed: false,
        };
        let actions = vec![
            Action::Emit(Self::event(&call, None)),
            Action::SpawnTunnel {
                call_id,
                config: self.config(call_id, true),
            },
            Action::Tunnel {
                call_id,
                command: TunnelCommand::CreateOutgoingCall {
                    call_id,
                    peer_id: peer.tunnel_peer_id(),
                },
            },
            Action::Tunnel {
                call_id,
                command: TunnelCommand::Proceed {
                    call_id,
                    hide_ip: false,
                    ice_servers,
                },
            },
            Action::ArmRingTimer { call_id },
        ];
        let info = Self::info(&call);
        self.calls.insert(call_id, call);
        Ok((info, actions))
    }

    /// `acceptCall`: only from `RINGING_INCOMING`. The tunnel's `accept` is held back until it has
    /// reported `Ringing` (RingRTC drops an accept that arrives in `ConnectingBeforeAccepted`).
    pub fn accept(&mut self, call_id: u64) -> Result<(Value, Vec<Action>), CallError> {
        let call = self.calls.get_mut(&call_id).ok_or_else(|| no_call(call_id))?;
        if call.state != CallState::RingingIncoming {
            return Err(CallError::new(format!(
                "Call {} is not in RINGING_INCOMING state (current: {})",
                wire_call_id(call_id),
                call.state
            )));
        }
        call.accept_pending = true;
        let mut actions = Self::accept_if_ready(call);
        call.state = CallState::Connecting;
        actions.push(Action::Emit(Self::event(call, None)));
        Ok((Self::info(call), actions))
    }

    /// `rejectCall`: answers busy to the caller's device, then ends without a hangup (as
    /// signal-cli does). Corvus: on an outgoing call (signal-cli throws a NullPointerException
    /// there) it hangs up instead.
    pub fn reject(&mut self, call_id: u64) -> Result<Vec<Action>, CallError> {
        let call = self.calls.get(&call_id).ok_or_else(|| no_call(call_id))?;
        match (call.outgoing, call.peer_device) {
            (false, Some(device)) => {
                let mut actions = vec![Action::Send {
                    peer: call.peer.clone(),
                    message: busy_message(call_id, Some(device)),
                }];
                actions.extend(self.end_call(call_id, "rejected", false));
                Ok(actions)
            }
            _ => Ok(self.end_call(call_id, "local_hangup", true)),
        }
    }

    /// `hangupCall`.
    pub fn hangup(&mut self, call_id: u64) -> Result<Vec<Action>, CallError> {
        if !self.calls.contains_key(&call_id) {
            return Err(no_call(call_id));
        }
        Ok(self.end_call(call_id, "local_hangup", true))
    }

    /// Ends every call (backend shutting down).
    pub fn shutdown(&mut self) -> Vec<Action> {
        let mut ids = self.call_ids();
        ids.sort_unstable();
        ids.into_iter()
            .flat_map(|id| self.end_call(id, "shutdown", true))
            .collect()
    }

    // ---- incoming CallMessages ----

    pub fn offer_disposition(&self, call_id: u64, has_subscribers: bool) -> OfferDisposition {
        if !has_subscribers {
            return OfferDisposition::Ignore("nobody subscribed to call events");
        }
        // Corvus: a redelivered offer for a call we know or just ended does not ring again.
        if self.calls.contains_key(&call_id) || self.recently_ended.contains(&call_id) {
            return OfferDisposition::Ignore("duplicate offer");
        }
        // Corvus: signal-cli would start a second tunnel; answer busy like the official apps.
        if self.active_call().is_some() {
            return OfferDisposition::Busy;
        }
        OfferDisposition::Ring
    }

    /// Answers busy to an offer that came in during another call. Corvus shows such a call as
    /// missed, so it still gets a `RINGING_INCOMING` event, followed by `ENDED` ("busy").
    pub fn incoming_offer_busy(&mut self, peer: Peer, sender_device: u32, call_id: u64) -> Vec<Action> {
        self.remember_ended(call_id);
        let mut call = Call {
            id: call_id,
            state: CallState::RingingIncoming,
            peer: peer.clone(),
            peer_device: Some(sender_device),
            outgoing: false,
            input_device: None,
            output_device: None,
            accept_pending: false,
            tunnel_ringing: false,
            hangup_relayed: false,
        };
        let ringing = Self::event(&call, None);
        call.state = CallState::Ended;
        vec![
            Action::Emit(ringing),
            Action::Send {
                peer,
                message: busy_message(call_id, Some(sender_device)),
            },
            Action::Emit(Self::event(&call, Some("busy"))),
        ]
    }

    /// An offer that should ring (see [`Machine::offer_disposition`]). Keys are serialized or raw
    /// identity keys; they are passed to the tunnel raw.
    #[allow(clippy::too_many_arguments)]
    pub fn incoming_offer(
        &mut self,
        peer: Peer,
        sender_device: u32,
        call_id: u64,
        opaque: Vec<u8>,
        age_ms: u64,
        local_identity_key: &[u8],
        remote_identity_key: &[u8],
        ice_servers: Vec<IceServer>,
    ) -> Vec<Action> {
        let call = Call {
            id: call_id,
            state: CallState::RingingIncoming,
            peer: peer.clone(),
            peer_device: Some(sender_device),
            outgoing: false,
            input_device: None,
            output_device: None,
            accept_pending: false,
            tunnel_ringing: false,
            hangup_relayed: false,
        };
        let actions = vec![
            Action::SpawnTunnel {
                call_id,
                config: self.config(call_id, false),
            },
            Action::Tunnel {
                call_id,
                command: TunnelCommand::ReceivedOffer {
                    call_id,
                    peer_id: peer.tunnel_peer_id(),
                    sender_device_id: sender_device,
                    opaque,
                    age: age_ms,
                    sender_identity_key: crate::protocol::raw_identity_key(remote_identity_key),
                    receiver_identity_key: crate::protocol::raw_identity_key(local_identity_key),
                },
            },
            Action::Tunnel {
                call_id,
                command: TunnelCommand::Proceed {
                    call_id,
                    hide_ip: false,
                    ice_servers,
                },
            },
            Action::Emit(Self::event(&call, None)),
            Action::ArmRingTimer { call_id },
        ];
        self.calls.insert(call_id, call);
        actions
    }

    /// The callee answered our outgoing call.
    pub fn incoming_answer(
        &mut self,
        call_id: u64,
        sender_device: u32,
        opaque: Vec<u8>,
        local_identity_key: &[u8],
        remote_identity_key: &[u8],
    ) -> Vec<Action> {
        let Some(call) = self.calls.get_mut(&call_id) else {
            return vec![];
        };
        // Corvus: an answer only makes sense for our own outgoing call.
        if !call.outgoing {
            return vec![];
        }
        let mut actions = vec![Action::Tunnel {
            call_id,
            command: TunnelCommand::ReceivedAnswer {
                opaque,
                sender_device_id: sender_device,
                sender_identity_key: crate::protocol::raw_identity_key(remote_identity_key),
                receiver_identity_key: crate::protocol::raw_identity_key(local_identity_key),
            },
        }];
        // Corvus: the first answering device wins (RingRTC hangs up on the others); signal-cli
        // overwrites the device and the state with every answer.
        if call.peer_device.is_none() {
            call.peer_device = Some(sender_device);
        }
        if call.state == CallState::RingingOutgoing {
            call.state = CallState::Connecting;
            actions.push(Action::Emit(Self::event(call, None)));
        }
        actions
    }

    pub fn incoming_ice(&mut self, call_id: u64, sender_device: u32, candidates: Vec<Vec<u8>>) -> Vec<Action> {
        if !self.calls.contains_key(&call_id) || candidates.is_empty() {
            return vec![];
        }
        vec![Action::Tunnel {
            call_id,
            command: TunnelCommand::ReceivedIce {
                sender_device_id: sender_device,
                candidates,
            },
        }]
    }

    /// `CallMessage.hangup` from the peer.
    pub fn incoming_hangup(
        &mut self,
        call_id: u64,
        sender_device: u32,
        kind: HangupKind,
        hangup_device: Option<u32>,
    ) -> Vec<Action> {
        let Some(call) = self.calls.get(&call_id) else {
            return vec![];
        };
        match kind {
            HangupKind::Normal => {
                // Corvus (as RingRTC does): once we talk to one device of the peer, hangups from
                // its other devices are not about our call.
                if call.peer_device.is_some_and(|d| d != sender_device) {
                    return vec![];
                }
                self.end_call(call_id, "remote_hangup", false)
            }
            // signal-cli ignores these as multi-device chatter. Corvus is a linked device, so they
            // are how it learns that the phone (or another device) took or turned down the call.
            HangupKind::Accepted | HangupKind::Declined | HangupKind::Busy => {
                if call.outgoing || hangup_device == Some(self.local_device_id) {
                    return vec![];
                }
                let reason = match kind {
                    HangupKind::Accepted => "acceptedonanotherdevice",
                    HangupKind::Declined => "declinedonanotherdevice",
                    _ => "busyonanotherdevice",
                };
                self.end_call(call_id, reason, false)
            }
            // Corvus: the callee needs to accept a message request first.
            HangupKind::NeedPermission => {
                if !call.outgoing {
                    return vec![];
                }
                self.end_call(call_id, "remote_need_permission", false)
            }
        }
    }

    pub fn incoming_busy(&mut self, call_id: u64) -> Vec<Action> {
        self.end_call(call_id, "remote_busy", false)
    }

    // ---- tunnel and timers ----

    pub fn tunnel_spawn_failed(&mut self, call_id: u64) -> Vec<Action> {
        // Corvus: nothing went out to the peer yet, so no hangup (signal-cli sends one).
        self.end_call(call_id, "tunnel_spawn_error", false)
    }

    pub fn tunnel_exited(&mut self, call_id: u64) -> Vec<Action> {
        self.end_call(call_id, "tunnel_exit", true)
    }

    pub fn ring_timeout(&mut self, call_id: u64) -> Vec<Action> {
        match self.calls.get(&call_id) {
            Some(call) if call.state.is_ringing() => self.end_call(call_id, "ring_timeout", true),
            _ => vec![],
        }
    }

    pub fn tunnel_event(&mut self, call_id: u64, event: TunnelEvent) -> Vec<Action> {
        let Some(call) = self.calls.get_mut(&call_id) else {
            return vec![];
        };
        let peer = call.peer.clone();
        let send = |message: CallMessage| {
            vec![Action::Send {
                peer: peer.clone(),
                message,
            }]
        };
        match event {
            TunnelEvent::Ready {
                input_device_name,
                output_device_name,
            } => {
                if input_device_name.is_some() {
                    call.input_device = input_device_name;
                }
                if output_device_name.is_some() {
                    call.output_device = output_device_name;
                }
                vec![]
            }
            TunnelEvent::SendOffer { opaque } => send(CallMessage {
                offer: Some(call_message::Offer {
                    id: Some(call_id),
                    r#type: Some(offer::Type::OfferAudioCall as i32),
                    opaque: Some(opaque),
                }),
                destination_device_id: call.peer_device,
                ..Default::default()
            }),
            TunnelEvent::SendAnswer { opaque } => send(CallMessage {
                answer: Some(call_message::Answer {
                    id: Some(call_id),
                    opaque: Some(opaque),
                }),
                destination_device_id: call.peer_device,
                ..Default::default()
            }),
            TunnelEvent::SendIce { candidates } => send(CallMessage {
                ice_update: candidates
                    .into_iter()
                    .map(|opaque| call_message::IceUpdate {
                        id: Some(call_id),
                        opaque: Some(opaque),
                    })
                    .collect(),
                destination_device_id: call.peer_device,
                ..Default::default()
            }),
            TunnelEvent::SendHangup {
                hangup_type,
                device_id,
            } => {
                // sendHangup asks us to send a hangup; it is not a state change.
                let kind = HangupKind::from_tunnel(&hangup_type);
                if hangup_type.contains("onanotherdevice") {
                    // RingRTC sends these to all of the peer's devices so the ones that did not
                    // take the call stop ringing; without the device id that took it (the stock
                    // tunnel drops it) the message would end the call on the wrong device, so
                    // signal-cli never sends them.
                    match device_id {
                        Some(device_id) => send(hangup_message(call_id, kind, device_id, None)),
                        None => vec![],
                    }
                } else {
                    if kind == HangupKind::Normal {
                        call.hangup_relayed = true;
                    }
                    send(hangup_message(
                        call_id,
                        kind,
                        device_id.unwrap_or(0),
                        call.peer_device,
                    ))
                }
            }
            TunnelEvent::SendBusy => send(busy_message(call_id, call.peer_device)),
            TunnelEvent::StateChange { state, reason } => {
                self.state_change(call_id, &state, reason.as_deref())
            }
            TunnelEvent::Error { message } => {
                tracing::warn!(call_id, %message, "call tunnel reported an error");
                self.end_call(call_id, "tunnel_error", true)
            }
            TunnelEvent::Unknown { .. } => vec![],
        }
    }

    fn state_change(&mut self, call_id: u64, state: &str, reason: Option<&str>) -> Vec<Action> {
        let call = self.calls.get_mut(&call_id).expect("caller checked");
        if state.starts_with("Incoming") {
            // Don't downgrade a call the user already accepted.
            if call.state == CallState::Connecting {
                return vec![];
            }
            call.state = CallState::RingingIncoming;
        } else if state.starts_with("Outgoing") {
            call.state = CallState::RingingOutgoing;
        } else if state == "Ringing" {
            // The tunnel can take the accept now.
            call.tunnel_ringing = true;
            return Self::accept_if_ready(call);
        } else if state == "Connected" {
            call.state = CallState::Connected;
        } else if state == "Connecting" {
            // RingRTC only reports Connecting again during an ICE restart.
            call.state = CallState::Reconnecting;
        } else if state == "Ended" || state == "Rejected" {
            let reason = reason.map_or_else(|| state.to_lowercase(), str::to_owned);
            // Corvus: no hangup back for calls the peer ended or RingRTC refused (signal-cli's
            // exclusion list never matches RingRTC's reason names, so it always sends one).
            let notify = state == "Ended" && !reason.starts_with("Remote");
            return self.end_call(call_id, &reason, notify);
        } else if state == "Concluded" {
            return vec![];
        }
        vec![Action::Emit(Self::event(call, reason))]
    }

    fn accept_if_ready(call: &mut Call) -> Vec<Action> {
        if call.accept_pending && call.tunnel_ringing {
            call.accept_pending = false;
            vec![Action::Tunnel {
                call_id: call.id,
                command: TunnelCommand::Accept,
            }]
        } else {
            vec![]
        }
    }

    fn remember_ended(&mut self, call_id: u64) {
        if self.recently_ended.len() == RECENTLY_ENDED {
            self.recently_ended.pop_front();
        }
        self.recently_ended.push_back(call_id);
    }

    /// signal-cli's `endCall`: `ENDED` event, a normal hangup to the peer unless the end came from
    /// the peer (or the tunnel already sent one), then `hangup` to the tunnel and stop it.
    pub fn end_call(&mut self, call_id: u64, reason: &str, notify_peer: bool) -> Vec<Action> {
        let Some(mut call) = self.calls.remove(&call_id) else {
            return vec![];
        };
        self.remember_ended(call_id);
        call.state = CallState::Ended;
        let mut actions = vec![Action::Emit(Self::event(&call, Some(reason)))];
        if notify_peer && !call.hangup_relayed {
            actions.push(Action::Send {
                peer: call.peer.clone(),
                message: hangup_message(call_id, HangupKind::Normal, 0, None),
            });
        }
        actions.push(Action::Tunnel {
            call_id,
            command: TunnelCommand::Hangup,
        });
        actions.push(Action::StopTunnel { call_id });
        actions
    }
}

pub fn busy_message(call_id: u64, destination_device: Option<u32>) -> CallMessage {
    CallMessage {
        busy: Some(call_message::Busy { id: Some(call_id) }),
        destination_device_id: destination_device,
        ..Default::default()
    }
}

pub fn hangup_message(
    call_id: u64,
    kind: HangupKind,
    device_id: u32,
    destination_device: Option<u32>,
) -> CallMessage {
    CallMessage {
        hangup: Some(call_message::Hangup {
            id: Some(call_id),
            r#type: Some(kind.to_proto() as i32),
            device_id: Some(device_id),
        }),
        destination_device_id: destination_device,
        ..Default::default()
    }
}
