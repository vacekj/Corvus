//! 1:1 voice calls for corvus-signal.
//!
//! Media (RingRTC/WebRTC, audio devices) runs in a separate `signal-call-tunnel` process per call,
//! as with signal-cli 0.14.10; this crate is the signaling half that signal-cli's Java
//! `CallManager` implements: it relays `CallMessage`s between presage and the tunnel, fetches TURN
//! servers, runs the call state machine and ring timeout, and produces the `callEvent`
//! notifications and the `subscribeCallEvents` / `startCall` / `acceptCall` / `rejectCall` /
//! `hangupCall` results Corvus expects. The protocol and the state machine are written down in
//! `signal-backend/docs/calls.md`.
//!
//! - [`protocol`]: the tunnel's JSON-line protocol.
//! - [`machine`]: the state machine, without I/O.
//! - [`manager`]: the async driver (tunnel processes, timers) and the [`CallHandle`] API.
//! - [`backend`]: the [`CallBackend`] trait the backend implements;
//!   [`presage_backend::PresageCallBackend`] implements it on a presage `Manager`.

pub mod backend;
pub mod events;
pub mod machine;
pub mod manager;
pub mod presage_backend;
pub mod protocol;

pub use backend::{CallBackend, CallError, IceServer, IncomingCallMessage, Peer};
pub use events::{CallEvent, CallState};
pub use manager::{CallDriver, CallHandle, CallManagerConfig, find_tunnel_binary, new};
