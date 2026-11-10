//! Call states and the JSON Corvus reads: `callEvent` notifications and the `startCall` /
//! `acceptCall` results (`docs/corvus-rpc-spec.md` sections 3.6 and 4.8).

use serde::Serialize;
use serde_json::{Value, json};

use crate::backend::Peer;

/// signal-cli's `CallInfo.State`; the names are the wire values.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CallState {
    Idle,
    RingingIncoming,
    RingingOutgoing,
    Connecting,
    Connected,
    Reconnecting,
    Ended,
}

impl CallState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Idle => "IDLE",
            Self::RingingIncoming => "RINGING_INCOMING",
            Self::RingingOutgoing => "RINGING_OUTGOING",
            Self::Connecting => "CONNECTING",
            Self::Connected => "CONNECTED",
            Self::Reconnecting => "RECONNECTING",
            Self::Ended => "ENDED",
        }
    }

    pub fn is_ringing(self) -> bool {
        matches!(self, Self::RingingIncoming | Self::RingingOutgoing)
    }
}

impl std::fmt::Display for CallState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// One `callEvent` (signal-cli's `JsonCallEvent`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CallEvent {
    pub call_id: u64,
    pub state: CallState,
    pub peer: Peer,
    pub is_outgoing: bool,
    pub input_device_name: Option<String>,
    pub output_device_name: Option<String>,
    pub reason: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct JsonCallEvent<'a> {
    call_id: i64,
    state: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    number: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    uuid: Option<String>,
    is_outgoing: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    input_device_name: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    output_device_name: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    reason: Option<&'a str>,
}

/// Call ids are random 64-bit values. signal-cli keeps them in a Java `long` and prints them
/// signed in every JSON-RPC result and notification; Corvus reads them as Int64. The tunnel
/// protocol uses the unsigned form of the same bits.
pub fn wire_call_id(call_id: u64) -> i64 {
    call_id as i64
}

impl CallEvent {
    /// The `params.result` object.
    pub fn to_json(&self) -> Value {
        serde_json::to_value(JsonCallEvent {
            call_id: wire_call_id(self.call_id),
            state: self.state.as_str(),
            number: self.peer.number.as_deref(),
            uuid: Some(self.peer.aci.to_string()),
            is_outgoing: self.is_outgoing,
            input_device_name: self.input_device_name.as_deref(),
            output_device_name: self.output_device_name.as_deref(),
            reason: self.reason.as_deref(),
        })
        .expect("call event serializes")
    }

    /// The whole JSON-RPC notification line for one subscription, as signal-cli sends it.
    pub fn notification(&self, subscription: u32) -> Value {
        json!({
            "jsonrpc": "2.0",
            "method": "callEvent",
            "params": {"subscription": subscription, "result": self.to_json()},
        })
    }
}

/// The result of `startCall` and `acceptCall` (signal-cli's `JsonCallInfo`: nulls included, plus
/// fixed codec fields Corvus ignores).
pub fn call_info_json(
    call_id: u64,
    state: CallState,
    input_device_name: Option<&str>,
    output_device_name: Option<&str>,
) -> Value {
    json!({
        "callId": wire_call_id(call_id),
        "state": state.as_str(),
        "inputDeviceName": input_device_name,
        "outputDeviceName": output_device_name,
        "codec": "opus",
        "sampleRate": 48000,
        "channels": 1,
        "ptimeMs": 20,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use presage::libsignal_service::prelude::Uuid;

    fn peer(number: Option<&str>) -> Peer {
        Peer::new(
            Uuid::parse_str("0b949a17-dc53-41b1-9ebc-dea99cb93920").unwrap(),
            number.map(str::to_owned),
        )
    }

    #[test]
    fn call_event_shape() {
        let ev = CallEvent {
            call_id: u64::MAX, // prints as -1, like signal-cli's long
            state: CallState::RingingIncoming,
            peer: peer(Some("+15550001111")),
            is_outgoing: false,
            input_device_name: None,
            output_device_name: None,
            reason: None,
        };
        assert_eq!(
            ev.notification(1),
            json!({"jsonrpc": "2.0", "method": "callEvent", "params": {"subscription": 1, "result": {
                "callId": -1, "state": "RINGING_INCOMING", "number": "+15550001111",
                "uuid": "0b949a17-dc53-41b1-9ebc-dea99cb93920", "isOutgoing": false}}})
        );
        let ended = CallEvent {
            call_id: 7,
            state: CallState::Ended,
            peer: peer(None),
            is_outgoing: true,
            input_device_name: Some("signal_input".into()),
            output_device_name: Some("signal_output".into()),
            reason: Some("remote_hangup".into()),
        };
        assert_eq!(
            ended.to_json(),
            json!({"callId": 7, "state": "ENDED", "uuid": "0b949a17-dc53-41b1-9ebc-dea99cb93920",
                   "isOutgoing": true, "inputDeviceName": "signal_input",
                   "outputDeviceName": "signal_output", "reason": "remote_hangup"})
        );
    }

    #[test]
    fn call_info_shape() {
        assert_eq!(
            call_info_json(5, CallState::RingingOutgoing, None, None),
            json!({"callId": 5, "state": "RINGING_OUTGOING", "inputDeviceName": null,
                   "outputDeviceName": null, "codec": "opus", "sampleRate": 48000, "channels": 1,
                   "ptimeMs": 20})
        );
    }
}
