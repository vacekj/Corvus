//! The async side: one driver task owns the [`Machine`], the tunnel processes and the ring timers;
//! [`CallHandle`]s talk to it over a channel.
//!
//! ```ignore
//! let (calls, driver, mut notifications) = corvus_calls::new(backend, CallManagerConfig::default());
//! tokio::task::spawn_local(driver.run());            // inside the backend's LocalSet
//! // JSON-RPC dispatch:   if let Some(r) = calls.handle_rpc(method, &params).await { ... }
//! // receive loop:        calls.call_message(IncomingCallMessage { .. });
//! // stdout writer:       while let Some(n) = notifications.recv().await { write_line(n) }
//! ```
//!
//! The runtime needs its IO and time drivers (`enable_all`); child processes are reaped through
//! tokio's SIGCHLD handling.

use std::collections::{HashMap, VecDeque};
use std::ffi::OsString;
use std::path::PathBuf;
use std::process::Stdio;
use std::time::Duration;

use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use tokio::sync::{mpsc, oneshot};
use tokio::time::Instant;

use crate::backend::{CallBackend, CallError, IceServer, IncomingCallMessage};
use crate::machine::{Action, HangupKind, Machine, OfferDisposition};
use crate::protocol::TunnelEvent;

#[derive(Debug, Clone)]
pub struct CallManagerConfig {
    /// Program and arguments that start one tunnel (see [`find_tunnel_binary`]).
    pub tunnel_command: Vec<OsString>,
    /// How long a call may ring before it is ended with `ring_timeout` (signal-cli: 60 s).
    pub ring_timeout: Duration,
    /// After `hangup` and closing stdin, how long the tunnel gets to exit before it is killed.
    /// The tunnel waits 500 ms after `hangup` so RingRTC can finish (signal-cli kills at once).
    pub tunnel_stop_grace: Duration,
    /// Id of the first `subscribeCallEvents` subscription. In signal-cli's single-account
    /// `jsonRpc` mode the receive subscription takes 0, so call events start at 1.
    pub first_subscription_id: u32,
    /// Audio device names put into the tunnel config (signal-cli leaves them out).
    pub input_device_name: Option<String>,
    pub output_device_name: Option<String>,
}

impl Default for CallManagerConfig {
    fn default() -> Self {
        Self {
            tunnel_command: vec![find_tunnel_binary().into_os_string()],
            ring_timeout: Duration::from_secs(60),
            tunnel_stop_grace: Duration::from_secs(2),
            first_subscription_id: 1,
            input_device_name: None,
            output_device_name: None,
        }
    }
}

pub const TUNNEL_BINARY: &str = "signal-call-tunnel";

/// Where the tunnel is: `$SIGNAL_CALL_TUNNEL_BIN`, else next to the running executable (inside
/// Corvus.app both live in `Contents/Helpers` or `Contents/MacOS`), else the bare name, which is
/// looked up on `$PATH` when spawned. signal-cli's order is the same with its install dir's `bin/`.
pub fn find_tunnel_binary() -> PathBuf {
    if let Some(p) = std::env::var_os("SIGNAL_CALL_TUNNEL_BIN").filter(|p| !p.is_empty()) {
        return PathBuf::from(p);
    }
    if let Ok(exe) = std::env::current_exe()
        && let Some(dir) = exe.parent()
    {
        let candidate = dir.join(TUNNEL_BINARY);
        if candidate.is_file() {
            return candidate;
        }
    }
    PathBuf::from(TUNNEL_BINARY)
}

type Reply<T> = oneshot::Sender<Result<T, CallError>>;

enum Request {
    Subscribe(Reply<u32>),
    Unsubscribe(u32, Reply<bool>),
    Start(String, Reply<Value>),
    Accept(u64, Reply<Value>),
    Reject(u64, Reply<Value>),
    Hangup(u64, Reply<Value>),
    Message(Box<IncomingCallMessage>),
    Shutdown(oneshot::Sender<()>),
}

/// Cheap to clone; usable from any task or thread.
#[derive(Clone)]
pub struct CallHandle {
    tx: mpsc::UnboundedSender<Request>,
}

fn gone() -> CallError {
    CallError::new("Call manager is not running")
}

impl CallHandle {
    async fn ask<T>(&self, make: impl FnOnce(Reply<T>) -> Request) -> Result<T, CallError> {
        let (tx, rx) = oneshot::channel();
        self.tx.send(make(tx)).map_err(|_| gone())?;
        rx.await.map_err(|_| gone())?
    }

    /// `subscribeCallEvents`: returns the subscription id. Until somebody subscribes, incoming
    /// offers are ignored (no tunnel, no busy), as in signal-cli.
    pub async fn subscribe_call_events(&self) -> Result<u32, CallError> {
        self.ask(Request::Subscribe).await
    }

    /// `unsubscribeCallEvents`: false for an unknown id.
    pub async fn unsubscribe_call_events(&self, subscription: u32) -> Result<bool, CallError> {
        self.ask(|r| Request::Unsubscribe(subscription, r)).await
    }

    /// `startCall`: `recipient` is an E.164 number or ACI UUID.
    pub async fn start_call(&self, recipient: &str) -> Result<Value, CallError> {
        let recipient = recipient.to_owned();
        self.ask(|r| Request::Start(recipient, r)).await
    }

    pub async fn accept_call(&self, call_id: u64) -> Result<Value, CallError> {
        self.ask(|r| Request::Accept(call_id, r)).await
    }

    pub async fn reject_call(&self, call_id: u64) -> Result<Value, CallError> {
        self.ask(|r| Request::Reject(call_id, r)).await
    }

    pub async fn hangup_call(&self, call_id: u64) -> Result<Value, CallError> {
        self.ask(|r| Request::Hangup(call_id, r)).await
    }

    /// Feed a `CallMessage` from the receive loop. Never blocks.
    pub fn call_message(&self, message: IncomingCallMessage) {
        let _ = self.tx.send(Request::Message(Box::new(message)));
    }

    /// Ends all calls (hangup to peers, tunnels stopped) and stops the driver.
    pub async fn shutdown(&self) {
        let (tx, rx) = oneshot::channel();
        if self.tx.send(Request::Shutdown(tx)).is_ok() {
            let _ = rx.await;
        }
    }

    /// JSON-RPC entry point for the call methods, with signal-cli's parameter handling. Returns
    /// `None` for any other method.
    pub async fn handle_rpc(&self, method: &str, params: &Value) -> Option<Result<Value, CallError>> {
        Some(match method {
            "subscribeCallEvents" => self.subscribe_call_events().await.map(Value::from),
            "unsubscribeCallEvents" => match params.get("subscription").and_then(Value::as_u64) {
                None => Err(CallError::new(
                    "Missing subscription parameter with subscription id",
                )),
                Some(id) => match self.unsubscribe_call_events(id as u32).await {
                    Ok(true) => Ok(Value::Null),
                    Ok(false) => Err(CallError::new("Unknown subscription id")),
                    Err(e) => Err(e),
                },
            },
            "startCall" => match recipient_param(params) {
                None => Err(CallError::new("No recipient given")),
                Some(r) => self.start_call(&r).await,
            },
            "acceptCall" | "rejectCall" | "hangupCall" => match call_id_param(params) {
                None => Err(CallError::new("No call ID given")),
                Some(id) => match method {
                    "acceptCall" => self.accept_call(id).await,
                    "rejectCall" => self.reject_call(id).await,
                    _ => self.hangup_call(id).await,
                },
            },
            _ => return None,
        })
    }
}

/// `recipient`: a string, or (signal-cli's argparse `nargs(1)`) a one-element array.
fn recipient_param(params: &Value) -> Option<String> {
    let v = params.get("recipient")?;
    let s = match v {
        Value::String(s) => s.as_str(),
        Value::Array(a) => a.first()?.as_str()?,
        _ => return None,
    };
    (!s.is_empty()).then(|| s.to_owned())
}

/// `callId`: any JSON number (signed as Corvus sends it, or unsigned) or a decimal string;
/// signal-cli takes `Number.longValue()`, i.e. the low 64 bits.
pub fn call_id_param(params: &Value) -> Option<u64> {
    match params.get("callId")? {
        Value::Number(n) => n
            .as_i64()
            .map(|i| i as u64)
            .or_else(|| n.as_u64())
            .or_else(|| n.as_f64().map(|f| f as i64 as u64)),
        Value::String(s) => s
            .trim()
            .parse::<i64>()
            .map(|i| i as u64)
            .or_else(|_| s.trim().parse::<u64>())
            .ok(),
        _ => None,
    }
}

enum TunnelMsg {
    Line(u64, String),
    Exited(u64, Option<i32>),
}

struct Tunnel {
    serial: u64,
    writer: Option<mpsc::UnboundedSender<String>>,
    stop: Option<oneshot::Sender<()>>,
}

/// Owns the calls. Run it with [`CallDriver::run`] on the task that may use the backend
/// (`spawn_local` when the backend's futures are not `Send`).
pub struct CallDriver<B: CallBackend> {
    backend: B,
    config: CallManagerConfig,
    machine: Machine,
    requests: mpsc::UnboundedReceiver<Request>,
    notifications: mpsc::UnboundedSender<Value>,
    subscriptions: Vec<u32>,
    next_subscription: u32,
    tunnels: HashMap<u64, Tunnel>,
    serials: HashMap<u64, u64>,
    next_serial: u64,
    tunnel_tx: mpsc::UnboundedSender<TunnelMsg>,
    tunnel_rx: mpsc::UnboundedReceiver<TunnelMsg>,
    timers: Vec<(Instant, u64)>,
    local_identity_key: Option<Vec<u8>>,
}

/// Creates the call manager. Returns the handle, the driver to run, and the stream of complete
/// `callEvent` JSON-RPC notifications to write to stdout.
pub fn new<B: CallBackend>(
    backend: B,
    config: CallManagerConfig,
) -> (CallHandle, CallDriver<B>, mpsc::UnboundedReceiver<Value>) {
    let (tx, requests) = mpsc::unbounded_channel();
    let (notifications, notifications_rx) = mpsc::unbounded_channel();
    let (tunnel_tx, tunnel_rx) = mpsc::unbounded_channel();
    let machine = Machine::new(
        backend.local_device_id(),
        config.input_device_name.clone(),
        config.output_device_name.clone(),
    );
    let driver = CallDriver {
        backend,
        next_subscription: config.first_subscription_id,
        config,
        machine,
        requests,
        notifications,
        subscriptions: Vec::new(),
        tunnels: HashMap::new(),
        serials: HashMap::new(),
        next_serial: 0,
        tunnel_tx,
        tunnel_rx,
        timers: Vec::new(),
        local_identity_key: None,
    };
    (CallHandle { tx }, driver, notifications_rx)
}

/// A random 64-bit call id, like signal-cli's `new BigInteger(64, new SecureRandom())`.
fn generate_call_id() -> u64 {
    rand::random()
}

impl<B: CallBackend> CallDriver<B> {
    /// Runs until every [`CallHandle`] is dropped or [`CallHandle::shutdown`] is called; then
    /// ends all calls.
    pub async fn run(mut self) {
        loop {
            let deadline = self.timers.iter().map(|(t, _)| *t).min();
            tokio::select! {
                request = self.requests.recv() => match request {
                    None => break,
                    Some(Request::Shutdown(done)) => {
                        self.shutdown().await;
                        let _ = done.send(());
                        return;
                    }
                    Some(request) => self.on_request(request).await,
                },
                Some(msg) = self.tunnel_rx.recv() => self.on_tunnel(msg).await,
                _ = tokio::time::sleep_until(deadline.unwrap_or_else(Instant::now)), if deadline.is_some() => {
                    self.on_timers().await;
                }
            }
        }
        self.shutdown().await;
    }

    async fn shutdown(&mut self) {
        let actions = self.machine.shutdown();
        self.execute(actions).await;
    }

    async fn on_request(&mut self, request: Request) {
        match request {
            Request::Subscribe(reply) => {
                let id = self.next_subscription;
                self.next_subscription += 1;
                self.subscriptions.push(id);
                let _ = reply.send(Ok(id));
            }
            Request::Unsubscribe(id, reply) => {
                let before = self.subscriptions.len();
                self.subscriptions.retain(|s| *s != id);
                let _ = reply.send(Ok(self.subscriptions.len() != before));
            }
            Request::Start(recipient, reply) => {
                let result = self.start(&recipient).await;
                let _ = reply.send(result);
            }
            Request::Accept(call_id, reply) => {
                let result = match self.machine.accept(call_id) {
                    Ok((info, actions)) => {
                        self.execute(actions).await;
                        Ok(info)
                    }
                    Err(e) => Err(e),
                };
                let _ = reply.send(result);
            }
            Request::Reject(call_id, reply) => {
                let result = match self.machine.reject(call_id) {
                    Ok(actions) => {
                        self.execute(actions).await;
                        Ok(Value::Null)
                    }
                    Err(e) => Err(e),
                };
                let _ = reply.send(result);
            }
            Request::Hangup(call_id, reply) => {
                let result = match self.machine.hangup(call_id) {
                    Ok(actions) => {
                        self.execute(actions).await;
                        Ok(Value::Null)
                    }
                    Err(e) => Err(e),
                };
                let _ = reply.send(result);
            }
            Request::Message(message) => self.on_call_message(*message).await,
            Request::Shutdown(_) => unreachable!("handled in run"),
        }
    }

    async fn turn_servers(&self) -> Vec<IceServer> {
        match self.backend.turn_servers().await {
            Ok(servers) => servers,
            Err(e) => {
                tracing::warn!(error = %e, "failed to get TURN servers, calling without relays");
                Vec::new()
            }
        }
    }

    async fn local_identity_key(&mut self) -> Result<Vec<u8>, CallError> {
        if let Some(k) = &self.local_identity_key {
            return Ok(k.clone());
        }
        let k = self.backend.local_identity_key().await?;
        self.local_identity_key = Some(k.clone());
        Ok(k)
    }

    async fn start(&mut self, recipient: &str) -> Result<Value, CallError> {
        let peer = self.backend.resolve_recipient(recipient).await?;
        let ice_servers = self.turn_servers().await;
        let call_id = generate_call_id();
        let (info, actions) = self.machine.start_outgoing(call_id, peer, ice_servers)?;
        let failed = self.execute(actions).await;
        if let Some(e) = failed.into_iter().find(|(id, _)| *id == call_id).map(|(_, e)| e) {
            return Err(CallError::new(format!(
                "Failed to start call: cannot run {}: {e}",
                self.config
                    .tunnel_command
                    .first()
                    .map(|p| p.to_string_lossy().into_owned())
                    .unwrap_or_default()
            )));
        }
        Ok(info)
    }

    async fn on_call_message(&mut self, m: IncomingCallMessage) {
        let IncomingCallMessage {
            sender,
            sender_device,
            message,
            age,
        } = m;
        // Meant for another of our devices.
        if let Some(dest) = message.destination_device_id
            && dest != self.backend.local_device_id()
        {
            return;
        }

        if let Some(offer) = message.offer {
            let call_id = offer.id.unwrap_or_default();
            match self
                .machine
                .offer_disposition(call_id, !self.subscriptions.is_empty())
            {
                OfferDisposition::Ignore(why) => {
                    tracing::debug!(call_id, why, "ignoring call offer");
                }
                OfferDisposition::Busy => {
                    let actions = self
                        .machine
                        .incoming_offer_busy(sender.clone(), sender_device, call_id);
                    self.execute(actions).await;
                }
                OfferDisposition::Ring => {
                    let keys = match self.local_identity_key().await {
                        Ok(local) => self
                            .backend
                            .remote_identity_key(&sender)
                            .await
                            .map(|remote| (local, remote)),
                        Err(e) => Err(e),
                    };
                    match keys {
                        Err(e) => tracing::warn!(call_id, error = %e, "no identity keys for the call offer, ignoring it"),
                        Ok((local, remote)) => {
                            let ice_servers = self.turn_servers().await;
                            let actions = self.machine.incoming_offer(
                                sender.clone(),
                                sender_device,
                                call_id,
                                offer.opaque.unwrap_or_default(),
                                age.as_millis().min(u64::MAX as u128) as u64,
                                &local,
                                &remote,
                                ice_servers,
                            );
                            self.execute(actions).await;
                        }
                    }
                }
            }
        }

        if let Some(answer) = message.answer {
            let call_id = answer.id.unwrap_or_default();
            if self.machine.has_call(call_id) {
                let keys = match self.local_identity_key().await {
                    Ok(local) => self
                        .backend
                        .remote_identity_key(&sender)
                        .await
                        .map(|remote| (local, remote)),
                    Err(e) => Err(e),
                };
                match keys {
                    Err(e) => {
                        tracing::warn!(call_id, error = %e, "no identity keys for the answer, ending the call");
                        let actions = self.machine.end_call(call_id, "identity_error", true);
                        self.execute(actions).await;
                    }
                    Ok((local, remote)) => {
                        let actions = self.machine.incoming_answer(
                            call_id,
                            sender_device,
                            answer.opaque.unwrap_or_default(),
                            &local,
                            &remote,
                        );
                        self.execute(actions).await;
                    }
                }
            }
        }

        // Grouped per call id; one receivedIce per CallMessage (signal-cli: one per candidate).
        let mut ice: Vec<(u64, Vec<Vec<u8>>)> = Vec::new();
        for update in message.ice_update {
            let id = update.id.unwrap_or_default();
            let Some(opaque) = update.opaque else { continue };
            match ice.iter_mut().find(|(i, _)| *i == id) {
                Some((_, list)) => list.push(opaque),
                None => ice.push((id, vec![opaque])),
            }
        }
        for (call_id, candidates) in ice {
            let actions = self.machine.incoming_ice(call_id, sender_device, candidates);
            self.execute(actions).await;
        }

        if let Some(hangup) = message.hangup {
            let actions = self.machine.incoming_hangup(
                hangup.id.unwrap_or_default(),
                sender_device,
                HangupKind::from_proto(hangup.r#type),
                hangup.device_id,
            );
            self.execute(actions).await;
        }

        if let Some(busy) = message.busy {
            let actions = self.machine.incoming_busy(busy.id.unwrap_or_default());
            self.execute(actions).await;
        }
        // `opaque` (group call signaling) is not supported.
    }

    async fn on_tunnel(&mut self, msg: TunnelMsg) {
        match msg {
            TunnelMsg::Line(serial, line) => {
                let Some(&call_id) = self.serials.get(&serial) else {
                    return;
                };
                let line = line.trim();
                if line.is_empty() {
                    return;
                }
                match TunnelEvent::parse(line) {
                    Ok(event) => {
                        let actions = self.machine.tunnel_event(call_id, event);
                        self.execute(actions).await;
                    }
                    Err(e) => tracing::warn!(call_id, error = %e, "bad line from call tunnel"),
                }
            }
            TunnelMsg::Exited(serial, code) => {
                let Some(call_id) = self.serials.remove(&serial) else {
                    return;
                };
                tracing::debug!(call_id, ?code, "call tunnel exited");
                if self.tunnels.get(&call_id).is_some_and(|t| t.serial == serial) {
                    self.tunnels.remove(&call_id);
                    let actions = self.machine.tunnel_exited(call_id);
                    self.execute(actions).await;
                }
            }
        }
    }

    async fn on_timers(&mut self) {
        let now = Instant::now();
        let (due, rest): (Vec<_>, Vec<_>) = self.timers.drain(..).partition(|(t, _)| *t <= now);
        self.timers = rest;
        for (_, call_id) in due {
            let actions = self.machine.ring_timeout(call_id);
            self.execute(actions).await;
        }
    }

    fn emit(&self, event: &crate::events::CallEvent) {
        for &subscription in &self.subscriptions {
            let _ = self.notifications.send(event.notification(subscription));
        }
    }

    /// Carries out actions in order. Returns the calls whose tunnel could not be started.
    async fn execute(&mut self, actions: Vec<Action>) -> Vec<(u64, std::io::Error)> {
        let mut failed = Vec::new();
        let mut queue: VecDeque<Action> = actions.into();
        while let Some(action) = queue.pop_front() {
            match action {
                Action::Emit(event) => self.emit(&event),
                Action::SpawnTunnel { call_id, config } => {
                    match self.spawn_tunnel(call_id, config.to_line()) {
                        Ok(()) => {}
                        Err(e) => {
                            tracing::error!(call_id, error = %e, "failed to start the call tunnel");
                            failed.push((call_id, e));
                            // Ends the call; the remaining queued tunnel commands are dropped.
                            let mut end = self.machine.tunnel_spawn_failed(call_id);
                            end.extend(queue.drain(..).filter(|a| !targets_call(a, call_id)));
                            queue = end.into();
                        }
                    }
                }
                Action::Tunnel { call_id, command } => {
                    if let Some(writer) = self.tunnels.get(&call_id).and_then(|t| t.writer.as_ref()) {
                        let _ = writer.send(command.to_line());
                    }
                }
                Action::StopTunnel { call_id } => {
                    if let Some(tunnel) = self.tunnels.get_mut(&call_id) {
                        tunnel.writer.take(); // stdin closes once the queued lines are written
                        if let Some(stop) = tunnel.stop.take() {
                            let _ = stop.send(());
                        }
                    }
                    self.tunnels.remove(&call_id);
                }
                Action::Send { peer, message } => {
                    if let Err(e) = self.backend.send_call_message(&peer, message).await {
                        tracing::warn!(error = %e, "failed to send call message");
                    }
                }
                Action::ArmRingTimer { call_id } => {
                    self.timers
                        .push((Instant::now() + self.config.ring_timeout, call_id));
                }
            }
        }
        failed
    }

    fn spawn_tunnel(&mut self, call_id: u64, config_line: String) -> std::io::Result<()> {
        let (program, args) = self
            .config
            .tunnel_command
            .split_first()
            .ok_or_else(|| std::io::Error::other("no tunnel command configured"))?;
        let mut child = Command::new(program)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()?;
        let mut stdin = child.stdin.take().expect("piped stdin");
        let stdout = child.stdout.take().expect("piped stdout");
        let stderr = child.stderr.take().expect("piped stderr");

        let serial = self.next_serial;
        self.next_serial += 1;

        // stdin: config line first, then commands in order; closing the channel closes stdin.
        let (writer, mut lines) = mpsc::unbounded_channel::<String>();
        let _ = writer.send(config_line);
        tokio::spawn(async move {
            while let Some(line) = lines.recv().await {
                let mut bytes = line.into_bytes();
                bytes.push(b'\n');
                if stdin.write_all(&bytes).await.is_err() || stdin.flush().await.is_err() {
                    break;
                }
            }
        });

        // stdout: control events.
        let events = self.tunnel_tx.clone();
        let reader = tokio::spawn(async move {
            let mut lines = BufReader::new(stdout).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                if events.send(TunnelMsg::Line(serial, line)).is_err() {
                    break;
                }
            }
        });

        // stderr: the tunnel's log (env_logger), only into our log.
        tokio::spawn(async move {
            let mut lines = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                tracing::debug!(target: "corvus_calls::tunnel", call_id, "{line}");
            }
        });

        // Exit: on its own, or after a stop request plus grace period (then killed).
        let (stop, stop_rx) = oneshot::channel::<()>();
        let grace = self.config.tunnel_stop_grace;
        let exited = self.tunnel_tx.clone();
        tokio::spawn(async move {
            let status = tokio::select! {
                status = child.wait() => status,
                _ = stop_rx => match tokio::time::timeout(grace, child.wait()).await {
                    Ok(status) => status,
                    Err(_) => {
                        let _ = child.start_kill();
                        child.wait().await
                    }
                },
            };
            // Deliver the last stdout lines before the exit notice.
            let _ = tokio::time::timeout(Duration::from_secs(1), reader).await;
            let code = status.ok().and_then(|s| s.code());
            let _ = exited.send(TunnelMsg::Exited(serial, code));
        });

        self.serials.insert(serial, call_id);
        self.tunnels.insert(
            call_id,
            Tunnel {
                serial,
                writer: Some(writer),
                stop: Some(stop),
            },
        );
        Ok(())
    }
}

fn targets_call(action: &Action, id: u64) -> bool {
    matches!(action,
        Action::Tunnel { call_id, .. } | Action::StopTunnel { call_id } | Action::ArmRingTimer { call_id }
            if *call_id == id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn call_id_params() {
        assert_eq!(call_id_param(&json!({"callId": 5})), Some(5));
        assert_eq!(call_id_param(&json!({"callId": -1})), Some(u64::MAX));
        assert_eq!(call_id_param(&json!({"callId": 18446744073709551615u64})), Some(u64::MAX));
        assert_eq!(call_id_param(&json!({"callId": "-2"})), Some(u64::MAX - 1));
        assert_eq!(call_id_param(&json!({"callId": "18446744073709551614"})), Some(u64::MAX - 1));
        assert_eq!(call_id_param(&json!({})), None);
        assert_eq!(call_id_param(&json!({"callId": true})), None);
    }

    #[test]
    fn recipient_params() {
        assert_eq!(recipient_param(&json!({"recipient": "+1555"})).as_deref(), Some("+1555"));
        assert_eq!(recipient_param(&json!({"recipient": ["+1555"]})).as_deref(), Some("+1555"));
        assert_eq!(recipient_param(&json!({"recipient": ""})), None);
        assert_eq!(recipient_param(&json!({})), None);
    }
}
