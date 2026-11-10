//! Corvus: TLS proxy accessors on [`PushService`] (see `crate::tls_proxy`).

use super::PushService;
use crate::tls_proxy::TlsProxy;

impl PushService {
    /// The Signal TLS proxy this service connects through, if any.
    pub fn tls_proxy(&self) -> Option<&TlsProxy> {
        self.cfg.tls_proxy.as_ref()
    }
}

#[cfg(test)]
mod tests {
    use crate::{configuration::SignalServers, push_service::PushService, tls_proxy::TlsProxy};

    #[test]
    fn explicit_proxy_is_kept() {
        let proxy = TlsProxy::parse("proxy.example.com:8443").unwrap();
        let service = PushService::new_with_tls_proxy(
            SignalServers::Production,
            None,
            "test",
            Some(proxy.clone()),
        );
        assert_eq!(service.tls_proxy(), Some(&proxy));
        let direct = PushService::new_with_tls_proxy(SignalServers::Production, None, "test", None);
        assert_eq!(direct.tls_proxy(), None);
    }
}
