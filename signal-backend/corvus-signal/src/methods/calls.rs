//! 1:1 voice calls: subscribeCallEvents, startCall, acceptCall, rejectCall, hangupCall.
//!
//! The signaling lives in the `corvus-calls` crate; media runs in a `signal-call-tunnel` process
//! per call (shipped next to this binary). The call manager starts on the first
//! `subscribeCallEvents`: until Corvus subscribes, incoming offers are ignored, as in signal-cli.

use std::cell::OnceCell;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::Duration;

use corvus_calls::presage_backend::PresageCallBackend;
use corvus_calls::{CallHandle, CallManagerConfig, IncomingCallMessage, Peer};
use presage::libsignal_service::content::{Content, ContentBody};
use presage::libsignal_service::protocol::ServiceId;
use serde_json::Value;

use crate::ctx::Ctx;
use crate::method;
use crate::rpc::{Method, RpcError};

pub const METHODS: &[Method] = &[
    method!("subscribeCallEvents", subscribe),
    method!("unsubscribeCallEvents", unsubscribe),
    method!("startCall", start_call),
    method!("acceptCall", accept_call),
    method!("rejectCall", reject_call),
    method!("hangupCall", hangup_call),
];

async fn subscribe(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    call_method(ctx, "subscribeCallEvents", p).await
}
async fn unsubscribe(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    call_method(ctx, "unsubscribeCallEvents", p).await
}
async fn start_call(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    call_method(ctx, "startCall", p).await
}
async fn accept_call(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    call_method(ctx, "acceptCall", p).await
}
async fn reject_call(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    call_method(ctx, "rejectCall", p).await
}
async fn hangup_call(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    call_method(ctx, "hangupCall", p).await
}

thread_local! {
    static CALLS: OnceCell<CallHandle> = const { OnceCell::new() };
}

fn handle() -> Option<CallHandle> {
    CALLS.with(|c| c.get().cloned())
}

/// The tunnel binary, or `None` when it is neither next to us nor on `$PATH`.
fn tunnel_binary() -> Option<PathBuf> {
    let found = corvus_calls::find_tunnel_binary();
    if found.is_absolute() {
        return found.is_file().then_some(found);
    }
    std::env::var_os("PATH")?
        .to_str()?
        .split(':')
        .map(|dir| Path::new(dir).join(&found))
        .find(|p| p.is_file())
}

fn start(ctx: &Rc<Ctx>) -> Result<CallHandle, RpcError> {
    if let Some(h) = handle() {
        return Ok(h);
    }
    let a = ctx.account()?;
    let tunnel = tunnel_binary().ok_or_else(|| RpcError::failed("Voice calls need signal-call-tunnel, which is missing"))?;
    let config = CallManagerConfig {
        tunnel_command: vec![tunnel.into_os_string()],
        ..Default::default()
    };
    let (h, driver, mut events) = corvus_calls::new(PresageCallBackend::new(a.manager()), config);
    tokio::task::spawn_local(driver.run());
    let out = ctx.out.clone();
    tokio::task::spawn_local(async move {
        while let Some(event) = events.recv().await {
            out.send(event.to_string());
        }
    });
    CALLS.with(|c| {
        let _ = c.set(h.clone());
    });
    Ok(h)
}

async fn call_method(ctx: Rc<Ctx>, method: &'static str, p: Value) -> Result<Value, RpcError> {
    let h = if method == "subscribeCallEvents" {
        start(&ctx)?
    } else {
        handle().ok_or_else(|| RpcError::failed("Not subscribed to call events"))?
    };
    match h.handle_rpc(method, &p).await {
        Some(result) => result.map_err(|e| RpcError::failed(e.0)),
        None => Err(RpcError::method_not_found(method)),
    }
}

/// Call signalling from the receive loop (offers, answers, ICE candidates, hangups, busy).
pub async fn on_incoming(ctx: &Rc<Ctx>, content: &Content) {
    let ContentBody::CallMessage(message) = &content.body else { return };
    let Some(h) = handle() else { return };
    let ServiceId::Aci(aci) = content.metadata.sender else { return };
    let Ok(account) = ctx.account() else { return };
    let uuid = aci.into();
    let number = account.number_of(&uuid).await;
    let age = (chrono::Utc::now() - content.metadata.server_timestamp)
        .to_std()
        .unwrap_or(Duration::ZERO);
    h.call_message(IncomingCallMessage {
        sender: Peer::new(uuid, number),
        sender_device: u32::from(content.metadata.sender_device),
        message: message.clone(),
        age,
    });
}

/// Ends running calls (hangup to the peer, tunnels stopped) before the process exits.
pub async fn shutdown() {
    if let Some(h) = handle() {
        h.shutdown().await;
    }
}
