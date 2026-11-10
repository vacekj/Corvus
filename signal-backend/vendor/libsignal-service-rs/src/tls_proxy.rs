//! Signal TLS proxy support (Corvus addition, see `vendor/CHANGES.md`).
//!
//! A Signal TLS proxy (<https://github.com/signalapp/Signal-TLS-Proxy>, links of the form
//! `https://signal.tube/#proxy.example.com`) is a TLS terminator in front of an SNI router:
//!
//! 1. the client opens TCP to `proxy_host:proxy_port` (443 by default) and does a TLS handshake
//!    with the proxy itself (SNI = the proxy host name, certificate checked against the system
//!    trust store, as libsignal-net does with `RootCertificates::Native`);
//! 2. inside that tunnel the client does its normal TLS handshake with the Signal service
//!    (SNI = `chat.signal.org`, `cdn2.signal.org`, ..., certificate checked against Signal's CA);
//! 3. the proxy reads the inner SNI and splices the connection to that service.
//!
//! reqwest has no hook below its TLS layer, so the outer layer is provided by a [`Forwarder`]: a
//! tiny loopback listener (one per proxy configuration, shared process-wide) that wraps every
//! accepted connection in the outer TLS session. The HTTP client gets a DNS resolver that resolves
//! *every* host name to that listener, so all HTTPS and websocket traffic of a [`PushService`]
//! (chat, storage, CDNs, attachment uploads) goes through the proxy, and a host the proxy does not
//! route fails instead of silently connecting directly.
//!
//! CDSI goes through libsignal-net, which has its own TLS proxy implementation; see
//! [`TlsProxy::to_connection_proxy_config`].
//!
//! [`PushService`]: crate::push_service::PushService

use std::{
    collections::HashMap,
    fmt, io,
    net::{IpAddr, Ipv4Addr, SocketAddr},
    str::FromStr,
    sync::{Arc, LazyLock, Mutex, RwLock, Weak},
    time::Duration,
};

use rustls::pki_types::{CertificateDer, ServerName};
use tokio::net::{TcpListener, TcpStream};

/// Default port of a Signal TLS proxy.
pub const DEFAULT_TLS_PROXY_PORT: u16 = 443;

/// Host of Signal's proxy share links (`https://signal.tube/#<proxy host>`).
pub const SIGNAL_PROXY_LINK_HOST: &str = "signal.tube";

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

/// A Signal TLS proxy endpoint.
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct TlsProxy {
    /// Lower-case host name or IP address (IPv6 without brackets).
    host: String,
    port: u16,
    /// DER certificates to trust for the *outer* TLS session instead of the system trust store.
    /// Only for tests with a self-signed proxy.
    root_certificates: Option<Arc<Vec<Vec<u8>>>>,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum TlsProxyParseError {
    #[error("empty proxy address")]
    Empty,
    #[error("unsupported proxy link: {0}")]
    UnsupportedLink(String),
    #[error("invalid proxy host: {0}")]
    InvalidHost(String),
    #[error("invalid proxy port: {0}")]
    InvalidPort(String),
}

impl TlsProxy {
    /// A proxy at `host:port`.
    pub fn new(
        host: impl AsRef<str>,
        port: u16,
    ) -> Result<Self, TlsProxyParseError> {
        let host = normalize_host(host.as_ref())?;
        if port == 0 {
            return Err(TlsProxyParseError::InvalidPort("0".into()));
        }
        Ok(Self {
            host,
            port,
            root_certificates: None,
        })
    }

    /// Parses what users paste: `host`, `host:port`, `[v6]:port`, a share link
    /// `https://signal.tube/#host[:port]` (also with the `sgnl://` scheme), or libsignal's
    /// `org.signal.tls://host[:port]`.
    pub fn parse(input: &str) -> Result<Self, TlsProxyParseError> {
        let input = input.trim();
        if input.is_empty() {
            return Err(TlsProxyParseError::Empty);
        }
        let lower = input.to_ascii_lowercase();
        let spec = if let Some((scheme, rest)) = lower.split_once("://") {
            match scheme {
                "https" | "http" | "sgnl" => {
                    let url = url::Url::parse(&lower).map_err(|_| {
                        TlsProxyParseError::UnsupportedLink(input.to_owned())
                    })?;
                    if url.host_str() != Some(SIGNAL_PROXY_LINK_HOST) {
                        return Err(TlsProxyParseError::UnsupportedLink(
                            input.to_owned(),
                        ));
                    }
                    match url.fragment().filter(|f| !f.is_empty()) {
                        Some(fragment) => fragment.to_owned(),
                        None => {
                            return Err(TlsProxyParseError::UnsupportedLink(
                                input.to_owned(),
                            ))
                        },
                    }
                },
                "org.signal.tls" => rest.trim_end_matches('/').to_owned(),
                _ => {
                    return Err(TlsProxyParseError::UnsupportedLink(
                        input.to_owned(),
                    ))
                },
            }
        } else {
            lower
        };
        let (host, port) = split_host_port(&spec)?;
        Self::new(host, port.unwrap_or(DEFAULT_TLS_PROXY_PORT))
    }

    pub fn host(&self) -> &str {
        &self.host
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    /// Trusts exactly these DER certificates for the outer TLS session (instead of the system
    /// trust store). Meant for tests against a self-signed proxy.
    pub fn with_root_certificates(
        mut self,
        certificates: impl IntoIterator<Item = Vec<u8>>,
    ) -> Self {
        self.root_certificates =
            Some(Arc::new(certificates.into_iter().collect()));
        self
    }

    /// The proxy as libsignal-net configuration, for connections libsignal-net makes itself
    /// (CDSI). Custom root certificates are not carried over: libsignal-net always checks the
    /// proxy against the system trust store.
    #[cfg(feature = "cdsi")]
    pub fn to_connection_proxy_config(
        &self,
    ) -> libsignal_net_infra::route::ConnectionProxyConfig {
        libsignal_net_infra::route::ConnectionProxyConfig::from_parts(
            libsignal_net_infra::route::SIGNAL_TLS_PROXY_SCHEME,
            &self.host,
            std::num::NonZeroU16::new(self.port),
            None,
        )
        .expect("a TLS proxy with a host and no credentials is always valid")
    }

    fn server_name(&self) -> io::Result<ServerName<'static>> {
        ServerName::try_from(self.host.clone()).map_err(|e| {
            io::Error::new(io::ErrorKind::InvalidInput, e.to_string())
        })
    }

    fn client_config(&self) -> Result<rustls::ClientConfig, rustls::Error> {
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let builder = rustls::ClientConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()?;
        let config = match &self.root_certificates {
            Some(certificates) => {
                let mut roots = rustls::RootCertStore::empty();
                for der in certificates.iter() {
                    roots.add(CertificateDer::from(der.clone()))?;
                }
                builder.with_root_certificates(roots).with_no_client_auth()
            },
            None => {
                use rustls_platform_verifier::BuilderVerifierExt;
                builder.with_platform_verifier()?.with_no_client_auth()
            },
        };
        Ok(config)
    }
}

impl fmt::Debug for TlsProxy {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("TlsProxy")
            .field("host", &self.host)
            .field("port", &self.port)
            .field("custom_roots", &self.root_certificates.is_some())
            .finish()
    }
}

/// `host` for the default port, `host:port` otherwise (`[v6]:port` for IPv6). This is the
/// normalized form Corvus passes as `--tls-proxy`.
impl fmt::Display for TlsProxy {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let bracketed = self.host.contains(':');
        match (bracketed, self.port == DEFAULT_TLS_PROXY_PORT) {
            (false, true) => write!(f, "{}", self.host),
            (true, true) => write!(f, "[{}]", self.host),
            (false, false) => write!(f, "{}:{}", self.host, self.port),
            (true, false) => write!(f, "[{}]:{}", self.host, self.port),
        }
    }
}

impl FromStr for TlsProxy {
    type Err = TlsProxyParseError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::parse(s)
    }
}

fn split_host_port(
    spec: &str,
) -> Result<(&str, Option<u16>), TlsProxyParseError> {
    let spec = spec.trim_end_matches('/');
    let parse_port = |p: &str| {
        p.parse::<u16>()
            .ok()
            .filter(|p| *p != 0)
            .ok_or_else(|| TlsProxyParseError::InvalidPort(p.to_owned()))
    };
    if let Some(rest) = spec.strip_prefix('[') {
        let (host, after) = rest
            .split_once(']')
            .ok_or_else(|| TlsProxyParseError::InvalidHost(spec.to_owned()))?;
        return match after {
            "" => Ok((host, None)),
            _ => match after.strip_prefix(':') {
                Some(port) => Ok((host, Some(parse_port(port)?))),
                None => Err(TlsProxyParseError::InvalidHost(spec.to_owned())),
            },
        };
    }
    match spec.matches(':').count() {
        0 => Ok((spec, None)),
        1 => {
            let (host, port) = spec.split_once(':').expect("one colon");
            Ok((host, Some(parse_port(port)?)))
        },
        // A bare IPv6 address.
        _ => Ok((spec, None)),
    }
}

fn normalize_host(host: &str) -> Result<String, TlsProxyParseError> {
    let host = host.trim().trim_end_matches('.').to_ascii_lowercase();
    if host.is_empty() {
        return Err(TlsProxyParseError::InvalidHost(host));
    }
    if host.parse::<IpAddr>().is_ok() {
        return Ok(host);
    }
    let valid_label = |label: &str| {
        !label.is_empty()
            && label.len() <= 63
            && !label.starts_with('-')
            && !label.ends_with('-')
            && label
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    };
    if host.len() > 253 || !host.split('.').all(valid_label) {
        return Err(TlsProxyParseError::InvalidHost(host));
    }
    Ok(host)
}

static DEFAULT_TLS_PROXY: RwLock<Option<TlsProxy>> = RwLock::new(None);

/// Sets the TLS proxy that [`PushService::new`](crate::push_service::PushService::new) uses
/// from now on (process-wide). Services that already exist keep their configuration.
pub fn set_default_tls_proxy(proxy: Option<TlsProxy>) {
    *DEFAULT_TLS_PROXY.write().unwrap_or_else(|e| e.into_inner()) = proxy;
}

/// The process-wide default TLS proxy, see [`set_default_tls_proxy`].
pub fn default_tls_proxy() -> Option<TlsProxy> {
    DEFAULT_TLS_PROXY
        .read()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
}

/// A loopback listener that wraps each accepted TCP connection in TLS to the proxy.
///
/// It runs on its own thread with a single-threaded tokio runtime, so it works no matter which
/// runtime (if any) the caller uses. It stops when the last handle is dropped.
pub(crate) struct Forwarder {
    local_addr: SocketAddr,
    _shutdown: tokio::sync::oneshot::Sender<()>,
}

impl Forwarder {
    pub(crate) fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }

    fn start(proxy: TlsProxy) -> io::Result<Self> {
        let config = proxy
            .client_config()
            .map_err(|e| io::Error::other(format!("TLS proxy setup: {e}")))?;
        let server_name = proxy.server_name()?;
        let listener =
            std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0))?;
        listener.set_nonblocking(true)?;
        let local_addr = listener.local_addr()?;
        let (shutdown, shutdown_rx) = tokio::sync::oneshot::channel::<()>();
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?;

        std::thread::Builder::new()
            .name("signal-tls-proxy".into())
            .spawn(move || {
                runtime.block_on(async move {
                    let listener = match TcpListener::from_std(listener) {
                        Ok(listener) => listener,
                        Err(error) => {
                            tracing::error!(%error, "TLS proxy forwarder failed to start");
                            return;
                        },
                    };
                    let connector =
                        tokio_rustls::TlsConnector::from(Arc::new(config));
                    let proxy = Arc::new(proxy);
                    tokio::select! {
                        _ = shutdown_rx => {},
                        _ = accept_loop(listener, connector, server_name, proxy) => {},
                    }
                });
                tracing::debug!("TLS proxy forwarder stopped");
            })?;

        Ok(Self {
            local_addr,
            _shutdown: shutdown,
        })
    }
}

async fn accept_loop(
    listener: TcpListener,
    connector: tokio_rustls::TlsConnector,
    server_name: ServerName<'static>,
    proxy: Arc<TlsProxy>,
) {
    loop {
        let (inbound, _) = match listener.accept().await {
            Ok(accepted) => accepted,
            Err(error) => {
                tracing::warn!(%error, "TLS proxy forwarder accept failed");
                tokio::time::sleep(Duration::from_millis(100)).await;
                continue;
            },
        };
        let connector = connector.clone();
        let server_name = server_name.clone();
        let proxy = proxy.clone();
        tokio::spawn(async move {
            if let Err(error) =
                forward(inbound, &connector, server_name, &proxy).await
            {
                tracing::warn!(%error, proxy = %proxy, "TLS proxy connection failed");
            }
        });
    }
}

async fn forward(
    mut inbound: TcpStream,
    connector: &tokio_rustls::TlsConnector,
    server_name: ServerName<'static>,
    proxy: &TlsProxy,
) -> io::Result<()> {
    let _ = inbound.set_nodelay(true);
    let outbound = tokio::time::timeout(CONNECT_TIMEOUT, async {
        let tcp =
            TcpStream::connect((proxy.host.as_str(), proxy.port)).await?;
        let _ = tcp.set_nodelay(true);
        connector.connect(server_name, tcp).await
    })
    .await
    .map_err(|_| {
        io::Error::new(io::ErrorKind::TimedOut, "connecting to TLS proxy")
    })??;
    let mut outbound = outbound;
    tokio::io::copy_bidirectional(&mut inbound, &mut outbound).await?;
    Ok(())
}

static FORWARDERS: LazyLock<Mutex<HashMap<TlsProxy, Weak<Forwarder>>>> =
    LazyLock::new(Default::default);

/// Returns the running forwarder for `proxy`, starting one if needed.
pub(crate) fn forwarder(proxy: &TlsProxy) -> io::Result<Arc<Forwarder>> {
    let mut forwarders = FORWARDERS.lock().unwrap_or_else(|e| e.into_inner());
    forwarders.retain(|_, f| f.strong_count() > 0);
    if let Some(forwarder) = forwarders.get(proxy).and_then(Weak::upgrade) {
        return Ok(forwarder);
    }
    let forwarder = Arc::new(Forwarder::start(proxy.clone())?);
    forwarders.insert(proxy.clone(), Arc::downgrade(&forwarder));
    Ok(forwarder)
}

/// DNS resolver that sends every host name to the forwarder.
///
/// If the forwarder could not be started, every lookup fails: falling back to a direct
/// connection would defeat the point of a proxy.
pub(crate) struct ProxyResolver {
    forwarder: Result<Arc<Forwarder>, Arc<io::Error>>,
}

impl ProxyResolver {
    pub(crate) fn new(proxy: &TlsProxy) -> Self {
        let forwarder = forwarder(proxy).map_err(|error| {
            tracing::error!(%error, "could not start the TLS proxy forwarder");
            Arc::new(error)
        });
        Self { forwarder }
    }
}

impl reqwest::dns::Resolve for ProxyResolver {
    fn resolve(&self, _name: reqwest::dns::Name) -> reqwest::dns::Resolving {
        let result = self
            .forwarder
            .as_ref()
            .map(|f| f.local_addr())
            .map_err(|e| io::Error::new(e.kind(), e.to_string()));
        Box::pin(async move {
            let addr = result?;
            Ok(Box::new(std::iter::once(addr)) as reqwest::dns::Addrs)
        })
    }
}

/// Routes all connections of `builder` through `proxy`.
pub(crate) fn apply(
    builder: reqwest::ClientBuilder,
    proxy: Option<&TlsProxy>,
) -> reqwest::ClientBuilder {
    match proxy {
        // System/environment HTTP proxies must not wrap the connection to the forwarder.
        Some(proxy) => builder
            .no_proxy()
            .dns_resolver(Arc::new(ProxyResolver::new(proxy))),
        None => builder,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_user_input() {
        let p = TlsProxy::parse("Proxy.Example.COM").unwrap();
        assert_eq!((p.host(), p.port()), ("proxy.example.com", 443));
        assert_eq!(p.to_string(), "proxy.example.com");

        let p = TlsProxy::parse(" proxy.example.com:8443 ").unwrap();
        assert_eq!((p.host(), p.port()), ("proxy.example.com", 8443));
        assert_eq!(p.to_string(), "proxy.example.com:8443");

        let p = TlsProxy::parse("https://signal.tube/#proxy.example.com").unwrap();
        assert_eq!((p.host(), p.port()), ("proxy.example.com", 443));

        let p =
            TlsProxy::parse("HTTPS://SIGNAL.TUBE/#Proxy.Example.com:4443").unwrap();
        assert_eq!((p.host(), p.port()), ("proxy.example.com", 4443));

        let p = TlsProxy::parse("sgnl://signal.tube/#proxy.example.com").unwrap();
        assert_eq!(p.host(), "proxy.example.com");

        let p = TlsProxy::parse("org.signal.tls://proxy.example.com:444").unwrap();
        assert_eq!((p.host(), p.port()), ("proxy.example.com", 444));

        let p = TlsProxy::parse("[2001:db8::1]:8443").unwrap();
        assert_eq!((p.host(), p.port()), ("2001:db8::1", 8443));
        assert_eq!(p.to_string(), "[2001:db8::1]:8443");

        let p = TlsProxy::parse("2001:db8::1").unwrap();
        assert_eq!((p.host(), p.port()), ("2001:db8::1", 443));

        let p = TlsProxy::parse("10.0.0.1:443").unwrap();
        assert_eq!((p.host(), p.port()), ("10.0.0.1", 443));
    }

    #[test]
    fn rejects_bad_input() {
        assert_eq!(TlsProxy::parse("  "), Err(TlsProxyParseError::Empty));
        assert!(matches!(
            TlsProxy::parse("https://example.com/#proxy.example.com"),
            Err(TlsProxyParseError::UnsupportedLink(_))
        ));
        assert!(matches!(
            TlsProxy::parse("https://signal.tube/"),
            Err(TlsProxyParseError::UnsupportedLink(_))
        ));
        assert!(matches!(
            TlsProxy::parse("socks5://proxy.example.com"),
            Err(TlsProxyParseError::UnsupportedLink(_))
        ));
        assert!(matches!(
            TlsProxy::parse("proxy.example.com:0"),
            Err(TlsProxyParseError::InvalidPort(_))
        ));
        assert!(matches!(
            TlsProxy::parse("proxy.example.com:99999"),
            Err(TlsProxyParseError::InvalidPort(_))
        ));
        assert!(matches!(
            TlsProxy::parse("proxy example.com"),
            Err(TlsProxyParseError::InvalidHost(_))
        ));
        assert!(matches!(
            TlsProxy::parse("-bad-.example.com"),
            Err(TlsProxyParseError::InvalidHost(_))
        ));
    }

    #[test]
    fn default_proxy_round_trips() {
        let proxy = TlsProxy::parse("proxy.example.com").unwrap();
        set_default_tls_proxy(Some(proxy.clone()));
        assert_eq!(default_tls_proxy(), Some(proxy));
        set_default_tls_proxy(None);
        assert_eq!(default_tls_proxy(), None);
    }

    #[cfg(feature = "cdsi")]
    #[test]
    fn converts_to_libsignal_net() {
        let proxy = TlsProxy::parse("proxy.example.com:8443").unwrap();
        assert!(proxy.to_connection_proxy_config().is_signal_transparent_proxy());
    }

    /// End-to-end through a fake proxy: outer TLS to the proxy (SNI = proxy host), inner TLS to
    /// the service (SNI = service host), all on loopback.
    mod end_to_end {
        use super::super::*;
        use rustls::pki_types::PrivatePkcs8KeyDer;
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        use tokio::sync::mpsc;

        fn server_config(host: &str) -> (Arc<rustls::ServerConfig>, Vec<u8>) {
            let rcgen::CertifiedKey { cert, signing_key } =
                rcgen::generate_simple_self_signed(vec![host.to_owned()])
                    .unwrap();
            let der = cert.der().to_vec();
            let key = PrivatePkcs8KeyDer::from(signing_key.serialize_der());
            let config = rustls::ServerConfig::builder_with_provider(Arc::new(
                rustls::crypto::ring::default_provider(),
            ))
            .with_safe_default_protocol_versions()
            .unwrap()
            .with_no_client_auth()
            .with_single_cert(vec![CertificateDer::from(der.clone())], key.into())
            .unwrap();
            (Arc::new(config), der)
        }

        /// A TLS server that answers one HTTP request per connection and reports the SNI.
        async fn spawn_service(
            host: &str,
        ) -> (SocketAddr, Vec<u8>, mpsc::UnboundedReceiver<Option<String>>) {
            let (config, der) = server_config(host);
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let addr = listener.local_addr().unwrap();
            let (tx, rx) = mpsc::unbounded_channel();
            tokio::spawn(async move {
                let acceptor = tokio_rustls::TlsAcceptor::from(config);
                loop {
                    let (tcp, _) = listener.accept().await.unwrap();
                    let acceptor = acceptor.clone();
                    let tx = tx.clone();
                    tokio::spawn(async move {
                        let Ok(mut tls) = acceptor.accept(tcp).await else {
                            return;
                        };
                        let _ = tx.send(
                            tls.get_ref().1.server_name().map(str::to_owned),
                        );
                        let mut request = Vec::new();
                        let mut buf = [0u8; 1024];
                        while !request.windows(4).any(|w| w == b"\r\n\r\n") {
                            let n = tls.read(&mut buf).await.unwrap();
                            if n == 0 {
                                return;
                            }
                            request.extend_from_slice(&buf[..n]);
                        }
                        let body = if request.starts_with(b"GET /v1/ping ") {
                            "pong"
                        } else {
                            "unexpected"
                        };
                        let response = format!(
                            "HTTP/1.1 200 OK\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{}",
                            body.len(),
                            body
                        );
                        tls.write_all(response.as_bytes()).await.unwrap();
                        tls.shutdown().await.unwrap();
                    });
                }
            });
            (addr, der, rx)
        }

        /// A fake Signal TLS proxy: terminates the outer TLS session and splices the plaintext
        /// (which is the client's inner TLS session) to `upstream`.
        async fn spawn_proxy(
            upstream: SocketAddr,
        ) -> (u16, Vec<u8>, mpsc::UnboundedReceiver<Option<String>>) {
            let (config, der) = server_config("localhost");
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let port = listener.local_addr().unwrap().port();
            let (tx, rx) = mpsc::unbounded_channel();
            tokio::spawn(async move {
                let acceptor = tokio_rustls::TlsAcceptor::from(config);
                loop {
                    let (tcp, _) = listener.accept().await.unwrap();
                    let acceptor = acceptor.clone();
                    let tx = tx.clone();
                    tokio::spawn(async move {
                        let Ok(mut tls) = acceptor.accept(tcp).await else {
                            let _ = tx.send(None);
                            return;
                        };
                        let _ = tx.send(
                            tls.get_ref().1.server_name().map(str::to_owned),
                        );
                        let mut upstream =
                            TcpStream::connect(upstream).await.unwrap();
                        let _ = tokio::io::copy_bidirectional(
                            &mut tls,
                            &mut upstream,
                        )
                        .await;
                    });
                }
            });
            (port, der, rx)
        }

        fn client(
            service_der: &[u8],
            proxy: &TlsProxy,
        ) -> reqwest::Client {
            let _ = rustls::crypto::ring::default_provider().install_default();
            let builder = reqwest::ClientBuilder::new()
                .tls_certs_only([reqwest::Certificate::from_der(service_der)
                    .unwrap()])
                .http1_only();
            apply(builder, Some(proxy)).build().unwrap()
        }

        #[tokio::test]
        async fn http_goes_through_the_proxy() {
            let (service_addr, service_der, mut service_sni) =
                spawn_service("chat.example.test").await;
            let (proxy_port, proxy_der, mut proxy_sni) =
                spawn_proxy(service_addr).await;
            let proxy = TlsProxy::new("localhost", proxy_port)
                .unwrap()
                .with_root_certificates([proxy_der]);

            let client = client(&service_der, &proxy);
            let response = client
                .get("https://chat.example.test/v1/ping")
                .send()
                .await
                .unwrap();
            assert_eq!(response.status(), 200);
            assert_eq!(response.text().await.unwrap(), "pong");

            // outer TLS: SNI is the proxy; inner TLS: SNI is the service
            assert_eq!(proxy_sni.recv().await.unwrap().as_deref(), Some("localhost"));
            assert_eq!(
                service_sni.recv().await.unwrap().as_deref(),
                Some("chat.example.test")
            );

            // a second client for the same proxy shares the forwarder
            let a = forwarder(&proxy).unwrap();
            let b = forwarder(&proxy).unwrap();
            assert!(Arc::ptr_eq(&a, &b));
        }

        #[tokio::test]
        async fn untrusted_proxy_fails_closed() {
            let (service_addr, service_der, mut service_sni) =
                spawn_service("chat.example.test").await;
            let (proxy_port, _proxy_der, _proxy_sni) =
                spawn_proxy(service_addr).await;
            // trust some other certificate for the proxy
            let (_, other_der) = server_config("localhost");
            let proxy = TlsProxy::new("localhost", proxy_port)
                .unwrap()
                .with_root_certificates([other_der]);

            let client = client(&service_der, &proxy);
            let result = client
                .get("https://chat.example.test/v1/ping")
                .send()
                .await;
            assert!(result.is_err());
            assert!(service_sni.try_recv().is_err(), "service was reached");
        }
    }
}

