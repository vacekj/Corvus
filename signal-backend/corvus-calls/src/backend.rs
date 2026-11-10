//! What the call manager needs from the rest of the backend.

use std::future::Future;
use std::time::Duration;

use presage::libsignal_service::prelude::Uuid;
use presage::proto::CallMessage;

pub use crate::protocol::IceServer;

/// The other party of a 1:1 call.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Peer {
    pub aci: Uuid,
    /// E.164, when known. `callEvent` carries it as `number` (Corvus prefers it over `uuid`).
    pub number: Option<String>,
}

impl Peer {
    pub fn new(aci: Uuid, number: Option<String>) -> Self {
        Self { aci, number }
    }

    /// The opaque peer id handed to RingRTC. Must stay the same for the whole call.
    pub fn tunnel_peer_id(&self) -> String {
        self.aci.to_string()
    }
}

/// A failure that ends up as a JSON-RPC error message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CallError(pub String);

impl CallError {
    pub fn new(message: impl Into<String>) -> Self {
        Self(message.into())
    }
}

impl std::fmt::Display for CallError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for CallError {}

/// A `CallMessage` taken from a decrypted envelope (`ContentBody::CallMessage`).
#[derive(Debug, Clone)]
pub struct IncomingCallMessage {
    pub sender: Peer,
    pub sender_device: u32,
    pub message: CallMessage,
    /// How long ago the server received the envelope (now - server timestamp). Passed to RingRTC
    /// as the offer age so it can drop offers for calls that are long over (signal-cli passes 0).
    pub age: Duration,
}

/// Implemented by the backend on top of presage. The futures need not be `Send`: the call driver
/// runs on the backend's `LocalSet` like everything else that touches the presage store.
pub trait CallBackend {
    /// Our device id (`local_device_id` in the tunnel config; filters `destinationDeviceId`).
    fn local_device_id(&self) -> u32;

    /// Resolves `startCall`'s `recipient` (E.164 number or ACI UUID string). The error message
    /// is shown to the user, e.g. `Recipient not registered: +1555...`.
    fn resolve_recipient(&self, recipient: &str) -> impl Future<Output = Result<Peer, CallError>>;

    /// Sends a `CallMessage` to `peer` as a normal (not online-only) sealed-sender or identified
    /// 1:1 message, like signal-cli's `SendHelper.sendCallMessage`. Call messages are never stored
    /// in a thread and never synced to our other devices.
    fn send_call_message(
        &self,
        peer: &Peer,
        message: CallMessage,
    ) -> impl Future<Output = Result<(), CallError>>;

    /// Short-lived TURN credentials (`GET /v2/calling/relays`). On error the call proceeds without
    /// relays (signal-cli does the same), which works only when a direct path exists.
    fn turn_servers(&self) -> impl Future<Output = Result<Vec<IceServer>, CallError>>;

    /// Our ACI identity public key, serialized (33 bytes, 0x05 prefix) or raw (32 bytes).
    fn local_identity_key(&self) -> impl Future<Output = Result<Vec<u8>, CallError>>;

    /// The peer's ACI identity public key from the protocol store, serialized or raw.
    fn remote_identity_key(&self, peer: &Peer) -> impl Future<Output = Result<Vec<u8>, CallError>>;
}
