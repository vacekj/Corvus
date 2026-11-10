//! Signal TLS proxy (`--tls-proxy host[:port]`, or a `https://signal.tube/#…` link). Every
//! connection (chat, storage, CDNs, CDSI) then goes through the proxy.

use presage::libsignal_service::tls_proxy::{TlsProxy, set_default_tls_proxy};

/// Called at the start of a run, before any connection is made, with the `--tls-proxy` value.
pub fn configure(proxy: Option<&str>) -> Result<(), String> {
    let Some(proxy) = proxy.map(str::trim).filter(|p| !p.is_empty()) else {
        // Inside the app the setting outlives a run: a run without a proxy clears an earlier one.
        set_default_tls_proxy(None);
        return Ok(());
    };
    let parsed = TlsProxy::parse(proxy).map_err(|e| format!("Invalid TLS proxy: {e}"))?;
    tracing::info!("using a TLS proxy");
    set_default_tls_proxy(Some(parsed));
    Ok(())
}
