//! Signal TLS proxy (`--tls-proxy host[:port]`, or a `https://signal.tube/#…` link). Every
//! connection (chat, storage, CDNs, CDSI) then goes through the proxy.

use presage::libsignal_service::tls_proxy::{TlsProxy, set_default_tls_proxy};

/// Called once at start-up, before any connection is made, with the `--tls-proxy` value.
pub fn configure(proxy: Option<&str>) -> Result<(), String> {
    let Some(proxy) = proxy.map(str::trim).filter(|p| !p.is_empty()) else {
        return Ok(());
    };
    let parsed = TlsProxy::parse(proxy).map_err(|e| format!("Invalid TLS proxy: {e}"))?;
    tracing::info!("using a TLS proxy");
    set_default_tls_proxy(Some(parsed));
    Ok(())
}
