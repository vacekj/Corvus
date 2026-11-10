//! The newline-delimited JSON protocol spoken with `signal-call-tunnel` over its stdin/stdout.
//!
//! The first stdin line is [`TunnelConfig`]; every later stdin line is a [`TunnelCommand`]. Every
//! stdout line is a [`TunnelEvent`]. Field names, the unsigned call id and the base64 encoding follow
//! signal-cli 0.14.10's `CallManager` (see `docs/calls.md`); the tunnel parses its input leniently, so
//! unknown fields are ignored on both sides.

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// First line written to the tunnel's stdin.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TunnelConfig {
    /// Unsigned representation of the call id.
    pub call_id: u64,
    pub is_outgoing: bool,
    pub local_device_id: u32,
    /// Omitted by signal-cli; the tunnel then uses `signal_input`/`signal_output` on macOS.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input_device_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_device_name: Option<String>,
}

/// One TURN/STUN server as the tunnel's `proceed` command carries it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IceServer {
    pub username: String,
    pub password: String,
    pub urls: Vec<String>,
}

/// Commands written to the tunnel's stdin after the config line.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum TunnelCommand {
    /// Outgoing call: create it in RingRTC. Followed by `proceed`.
    CreateOutgoingCall { call_id: u64, peer_id: String },
    /// Start ICE gathering with these servers (both directions).
    Proceed {
        call_id: u64,
        hide_ip: bool,
        ice_servers: Vec<IceServer>,
    },
    /// Incoming call: the caller's offer. Followed by `proceed`.
    ReceivedOffer {
        call_id: u64,
        peer_id: String,
        sender_device_id: u32,
        #[serde(with = "b64")]
        opaque: Vec<u8>,
        /// Milliseconds since the server received the offer (signal-cli always sends 0).
        age: u64,
        /// Raw 32-byte Curve25519 key (no 0x05 prefix) of the caller.
        #[serde(with = "b64")]
        sender_identity_key: Vec<u8>,
        /// Raw 32-byte Curve25519 key of our ACI identity.
        #[serde(with = "b64")]
        receiver_identity_key: Vec<u8>,
    },
    /// Outgoing call: the callee's answer. No call id (the tunnel has only one call).
    ReceivedAnswer {
        #[serde(with = "b64")]
        opaque: Vec<u8>,
        sender_device_id: u32,
        #[serde(with = "b64")]
        sender_identity_key: Vec<u8>,
        #[serde(with = "b64")]
        receiver_identity_key: Vec<u8>,
    },
    /// Remote ICE candidates (opaque blobs from `CallMessage.iceUpdate`).
    ReceivedIce {
        sender_device_id: u32,
        #[serde(with = "b64_list")]
        candidates: Vec<Vec<u8>>,
    },
    /// The user accepted the incoming call. Only valid once the tunnel reported `Ringing`.
    Accept,
    /// End the call; the tunnel hangs up in RingRTC and exits about 500 ms later.
    Hangup,
}

impl TunnelConfig {
    pub fn to_line(&self) -> String {
        serde_json::to_string(self).expect("tunnel config serializes")
    }
}

impl TunnelCommand {
    pub fn to_line(&self) -> String {
        serde_json::to_string(self).expect("tunnel command serializes")
    }

    pub fn kind(&self) -> &'static str {
        match self {
            Self::CreateOutgoingCall { .. } => "createOutgoingCall",
            Self::Proceed { .. } => "proceed",
            Self::ReceivedOffer { .. } => "receivedOffer",
            Self::ReceivedAnswer { .. } => "receivedAnswer",
            Self::ReceivedIce { .. } => "receivedIce",
            Self::Accept => "accept",
            Self::Hangup => "hangup",
        }
    }
}

/// Lines the tunnel writes to its stdout.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TunnelEvent {
    /// Audio devices are set up; the names are what clients should open.
    Ready {
        input_device_name: Option<String>,
        output_device_name: Option<String>,
    },
    /// Send `CallMessage.offer` (always an audio offer) to the peer.
    SendOffer { opaque: Vec<u8> },
    /// Send `CallMessage.answer` to the peer.
    SendAnswer { opaque: Vec<u8> },
    /// Send `CallMessage.iceUpdate` (one entry per candidate) to the peer.
    SendIce { candidates: Vec<Vec<u8>> },
    /// Send `CallMessage.hangup`. `hangup_type` is RingRTC's `HangupType` in lower case
    /// (`normal`, `acceptedonanotherdevice`, `declinedonanotherdevice`, `busyonanotherdevice`,
    /// `needpermission`). `device_id` is only present with the Corvus tunnel patch.
    SendHangup {
        hangup_type: String,
        device_id: Option<u32>,
    },
    /// Send `CallMessage.busy` to the peer.
    SendBusy,
    /// RingRTC call state: `Incoming(Audio)`, `Outgoing(Audio)`, `Ringing`, `Connected`,
    /// `Connecting`, `Ended`, `Rejected`, `Concluded`; `reason` is a `CallEndReason` name.
    StateChange {
        state: String,
        reason: Option<String>,
    },
    /// The tunnel failed (e.g. could not create the call); the call is over.
    Error { message: String },
    /// Any other `type`, ignored.
    Unknown { kind: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProtocolError(pub String);

impl std::fmt::Display for ProtocolError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ProtocolError {}

fn text(v: &Value, key: &str) -> Option<String> {
    v.get(key).and_then(|x| x.as_str()).map(str::to_owned)
}

fn blob(v: &Value, key: &str) -> Result<Vec<u8>, ProtocolError> {
    let s = v
        .get(key)
        .and_then(|x| x.as_str())
        .ok_or_else(|| ProtocolError(format!("missing {key}")))?;
    BASE64
        .decode(s)
        .map_err(|e| ProtocolError(format!("bad base64 in {key}: {e}")))
}

impl TunnelEvent {
    /// Parses one stdout line. Lenient in the same places signal-cli is: a missing `type` or an
    /// unknown one is [`TunnelEvent::Unknown`], a missing `hangupType` is `normal`, a missing error
    /// `message` is `unknown`.
    pub fn parse(line: &str) -> Result<Self, ProtocolError> {
        let v: Value = serde_json::from_str(line.trim())
            .map_err(|e| ProtocolError(format!("invalid JSON: {e}")))?;
        if !v.is_object() {
            return Err(ProtocolError("not a JSON object".into()));
        }
        let kind = text(&v, "type").unwrap_or_default();
        Ok(match kind.as_str() {
            "ready" => Self::Ready {
                input_device_name: text(&v, "inputDeviceName"),
                output_device_name: text(&v, "outputDeviceName"),
            },
            "sendOffer" => Self::SendOffer {
                opaque: blob(&v, "opaque")?,
            },
            "sendAnswer" => Self::SendAnswer {
                opaque: blob(&v, "opaque")?,
            },
            "sendIce" => {
                let list = v
                    .get("candidates")
                    .and_then(|c| c.as_array())
                    .ok_or_else(|| ProtocolError("missing candidates".into()))?;
                let mut candidates = Vec::with_capacity(list.len());
                for c in list {
                    candidates.push(blob(c, "opaque")?);
                }
                Self::SendIce { candidates }
            }
            "sendHangup" => Self::SendHangup {
                hangup_type: text(&v, "hangupType").unwrap_or_else(|| "normal".into()),
                device_id: v
                    .get("deviceId")
                    .and_then(|d| d.as_u64())
                    .and_then(|d| u32::try_from(d).ok()),
            },
            "sendBusy" => Self::SendBusy,
            "stateChange" => Self::StateChange {
                state: text(&v, "state").ok_or_else(|| ProtocolError("missing state".into()))?,
                reason: text(&v, "reason"),
            },
            "error" => Self::Error {
                message: text(&v, "message").unwrap_or_else(|| "unknown".into()),
            },
            _ => Self::Unknown { kind },
        })
    }
}

/// Signal identity keys are serialized with a 0x05 (DJB) type byte; RingRTC wants the raw 32-byte
/// Curve25519 key, as Signal-Android's `WebRtcUtil.getPublicKeyBytes()` passes it. Keys with the
/// prefix on one side and not on the other derive different SRTP keys and the call never connects.
pub fn raw_identity_key(serialized: &[u8]) -> Vec<u8> {
    if serialized.len() == 33 && serialized[0] == 0x05 {
        serialized[1..].to_vec()
    } else {
        serialized.to_vec()
    }
}

mod b64 {
    use super::BASE64;
    use base64::Engine;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(bytes: &[u8], s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&BASE64.encode(bytes))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<u8>, D::Error> {
        let s = String::deserialize(d)?;
        BASE64.decode(s).map_err(serde::de::Error::custom)
    }
}

mod b64_list {
    use super::BASE64;
    use base64::Engine;
    use serde::ser::SerializeSeq;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(list: &[Vec<u8>], s: S) -> Result<S::Ok, S::Error> {
        let mut seq = s.serialize_seq(Some(list.len()))?;
        for bytes in list {
            seq.serialize_element(&BASE64.encode(bytes))?;
        }
        seq.end()
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<Vec<u8>>, D::Error> {
        let list = Vec::<String>::deserialize(d)?;
        list.into_iter()
            .map(|s| BASE64.decode(s).map_err(serde::de::Error::custom))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn value(line: &str) -> Value {
        serde_json::from_str(line).unwrap()
    }

    #[test]
    fn config_line_matches_signal_cli() {
        let c = TunnelConfig {
            call_id: u64::MAX - 1,
            is_outgoing: true,
            local_device_id: 3,
            input_device_name: None,
            output_device_name: None,
        };
        // Same keys and order as signal-cli's buildConfig; the call id is unsigned.
        assert_eq!(
            c.to_line(),
            r#"{"call_id":18446744073709551614,"is_outgoing":true,"local_device_id":3}"#
        );
        let with_names = TunnelConfig {
            input_device_name: Some("in".into()),
            output_device_name: Some("out".into()),
            ..c
        };
        assert_eq!(
            value(&with_names.to_line()),
            json!({"call_id": 18446744073709551614u64, "is_outgoing": true, "local_device_id": 3,
                   "input_device_name": "in", "output_device_name": "out"})
        );
    }

    #[test]
    fn commands_encode_like_signal_cli() {
        let cases = [
            (
                TunnelCommand::CreateOutgoingCall {
                    call_id: 42,
                    peer_id: "0b949a17-dc53-41b1-9ebc-dea99cb93920".into(),
                },
                r#"{"type":"createOutgoingCall","callId":42,"peerId":"0b949a17-dc53-41b1-9ebc-dea99cb93920"}"#,
            ),
            (
                TunnelCommand::Proceed {
                    call_id: 42,
                    hide_ip: false,
                    ice_servers: vec![IceServer {
                        username: "u".into(),
                        password: "p".into(),
                        urls: vec!["turn:example.com:3478".into()],
                    }],
                },
                r#"{"type":"proceed","callId":42,"hideIp":false,"iceServers":[{"username":"u","password":"p","urls":["turn:example.com:3478"]}]}"#,
            ),
            (
                TunnelCommand::ReceivedOffer {
                    call_id: 100,
                    peer_id: "peer".into(),
                    sender_device_id: 3,
                    opaque: b"hello".to_vec(),
                    age: 0,
                    sender_identity_key: vec![1, 2, 3],
                    receiver_identity_key: vec![4, 5, 6],
                },
                r#"{"type":"receivedOffer","callId":100,"peerId":"peer","senderDeviceId":3,"opaque":"aGVsbG8=","age":0,"senderIdentityKey":"AQID","receiverIdentityKey":"BAUG"}"#,
            ),
            (
                TunnelCommand::ReceivedAnswer {
                    opaque: vec![1, 2, 3],
                    sender_device_id: 2,
                    sender_identity_key: vec![4, 5, 6],
                    receiver_identity_key: vec![7, 8, 9],
                },
                r#"{"type":"receivedAnswer","opaque":"AQID","senderDeviceId":2,"senderIdentityKey":"BAUG","receiverIdentityKey":"BwgJ"}"#,
            ),
            (
                TunnelCommand::ReceivedIce {
                    sender_device_id: 2,
                    candidates: vec![vec![1, 2, 3], vec![4, 5, 6]],
                },
                r#"{"type":"receivedIce","senderDeviceId":2,"candidates":["AQID","BAUG"]}"#,
            ),
            (TunnelCommand::Accept, r#"{"type":"accept"}"#),
            (TunnelCommand::Hangup, r#"{"type":"hangup"}"#),
        ];
        for (cmd, line) in cases {
            assert_eq!(cmd.to_line(), line);
            assert_eq!(serde_json::from_str::<TunnelCommand>(line).unwrap(), cmd);
            assert_eq!(value(line)["type"], cmd.kind());
        }
    }

    #[test]
    fn parses_tunnel_events() {
        // Lines exactly as the tunnel's platform.rs / control.rs format them.
        let cases = [
            (
                r#"{"type":"ready","inputDeviceName":"signal_input","outputDeviceName":"signal_output"}"#,
                TunnelEvent::Ready {
                    input_device_name: Some("signal_input".into()),
                    output_device_name: Some("signal_output".into()),
                },
            ),
            (
                r#"{"type":"sendOffer","callId":42,"opaque":"AQID","callMediaType":"audio"}"#,
                TunnelEvent::SendOffer {
                    opaque: vec![1, 2, 3],
                },
            ),
            (
                r#"{"type":"sendAnswer","callId":99,"opaque":"BAUG"}"#,
                TunnelEvent::SendAnswer {
                    opaque: vec![4, 5, 6],
                },
            ),
            (
                r#"{"type":"sendIce","callId":7,"candidates":[{"opaque":"ChQ="},{"opaque":"Hig="}]}"#,
                TunnelEvent::SendIce {
                    candidates: vec![vec![10, 20], vec![30, 40]],
                },
            ),
            (
                r#"{"type":"sendHangup","callId":50,"hangupType":"normal"}"#,
                TunnelEvent::SendHangup {
                    hangup_type: "normal".into(),
                    device_id: None,
                },
            ),
            (
                r#"{"type":"sendHangup","callId":50,"hangupType":"acceptedonanotherdevice","deviceId":2}"#,
                TunnelEvent::SendHangup {
                    hangup_type: "acceptedonanotherdevice".into(),
                    device_id: Some(2),
                },
            ),
            (
                r#"{"type":"sendHangup","callId":50}"#,
                TunnelEvent::SendHangup {
                    hangup_type: "normal".into(),
                    device_id: None,
                },
            ),
            (r#"{"type":"sendBusy","callId":8}"#, TunnelEvent::SendBusy),
            (
                r#"{"type":"stateChange","state":"Ended","reason":"Timeout"}"#,
                TunnelEvent::StateChange {
                    state: "Ended".into(),
                    reason: Some("Timeout".into()),
                },
            ),
            (
                r#"{"type":"stateChange","state":"Incoming(Audio)"}"#,
                TunnelEvent::StateChange {
                    state: "Incoming(Audio)".into(),
                    reason: None,
                },
            ),
            (
                r#"{"type":"error","message":"failed to proceed: x"}"#,
                TunnelEvent::Error {
                    message: "failed to proceed: x".into(),
                },
            ),
            (
                r#"{"type":"error"}"#,
                TunnelEvent::Error {
                    message: "unknown".into(),
                },
            ),
            (
                r#"{"type":"somethingNew","x":1}"#,
                TunnelEvent::Unknown {
                    kind: "somethingNew".into(),
                },
            ),
            (
                r#"{"callId":1}"#,
                TunnelEvent::Unknown { kind: "".into() },
            ),
        ];
        for (line, event) in cases {
            assert_eq!(TunnelEvent::parse(line).unwrap(), event, "{line}");
        }
    }

    #[test]
    fn rejects_malformed_events() {
        for line in [
            "not json",
            "[1,2]",
            r#"{"type":"sendOffer"}"#,
            r#"{"type":"sendOffer","opaque":"!!"}"#,
            r#"{"type":"sendIce","candidates":[{"x":1}]}"#,
            r#"{"type":"stateChange"}"#,
        ] {
            assert!(TunnelEvent::parse(line).is_err(), "{line}");
        }
    }

    #[test]
    fn strips_djb_prefix_only_from_33_byte_keys() {
        let mut k = vec![0x05];
        k.extend([7u8; 32]);
        assert_eq!(raw_identity_key(&k), vec![7u8; 32]);
        assert_eq!(raw_identity_key(&[7u8; 32]), vec![7u8; 32]);
        let mut other = vec![0x06];
        other.extend([7u8; 32]);
        assert_eq!(raw_identity_key(&other), other);
    }
}
