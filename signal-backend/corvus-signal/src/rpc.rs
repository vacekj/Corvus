//! JSON-RPC 2.0 framing over stdin/stdout: one compact JSON object per line.
//!
//! Responses echo the request id exactly and never carry a `method` key. Errors always have a
//! string `message` (Corvus shows it to the user). Notifications (`receive`) go through the same
//! single writer so lines never interleave.

use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::rc::Rc;

use serde_json::{Map, Value, json};
use tokio::io::{AsyncWrite, AsyncWriteExt};
use tokio::sync::{mpsc, oneshot};

use crate::ctx::Ctx;

pub const PARSE_ERROR: i64 = -32700;
pub const INVALID_REQUEST: i64 = -32600;
pub const METHOD_NOT_FOUND: i64 = -32601;
pub const INVALID_PARAMS: i64 = -32602;
/// A method failed (network, protocol, unknown recipient, ...); signal-cli uses -1 here too.
pub const FAILURE: i64 = -1;
/// The account is not linked yet (or the store could not be opened).
pub const NOT_LINKED: i64 = -2;
/// The method exists in the protocol but this backend does not implement it yet.
pub const NOT_SUPPORTED: i64 = -3;

#[derive(Debug, Clone, PartialEq)]
pub struct RpcError {
    pub code: i64,
    pub message: String,
}

impl RpcError {
    pub fn new(code: i64, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    pub fn failed(message: impl Into<String>) -> Self {
        Self::new(FAILURE, message)
    }

    pub fn invalid_params(message: impl Into<String>) -> Self {
        Self::new(INVALID_PARAMS, message)
    }

    pub fn method_not_found(method: &str) -> Self {
        Self::new(METHOD_NOT_FOUND, format!("Method not found: {method}"))
    }

    pub fn not_supported(what: &str) -> Self {
        Self::new(NOT_SUPPORTED, format!("{what} is not supported yet"))
    }

    pub fn to_json(&self) -> Value {
        json!({"code": self.code, "message": self.message})
    }
}

impl std::fmt::Display for RpcError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

/// Converts any displayable error into a user-facing failure.
pub fn fail<E: std::fmt::Display>(e: E) -> RpcError {
    RpcError::failed(e.to_string())
}

#[derive(Debug, PartialEq)]
pub enum Incoming {
    Request {
        id: Value,
        method: String,
        params: Value,
    },
    /// A request without an id: handled, but never answered.
    Notification { method: String, params: Value },
    /// Answered with an error right away.
    Invalid { id: Value, error: RpcError },
}

/// Parses one stdin line. `None` for blank lines.
pub fn parse_line(line: &str) -> Option<Incoming> {
    let line = line.trim_matches(|c: char| c.is_whitespace());
    if line.is_empty() {
        return None;
    }
    let value: Value = match serde_json::from_str(line) {
        Ok(v) => v,
        Err(e) => {
            return Some(Incoming::Invalid {
                id: Value::Null,
                error: RpcError::new(PARSE_ERROR, format!("Parse error: {e}")),
            });
        }
    };
    let Value::Object(mut obj) = value else {
        return Some(Incoming::Invalid {
            id: Value::Null,
            error: RpcError::new(INVALID_REQUEST, "Invalid request: not a JSON object"),
        });
    };
    let id = obj.remove("id");
    let id_valid = matches!(
        id,
        None | Some(Value::Number(_)) | Some(Value::String(_)) | Some(Value::Null)
    );
    let method = match obj.remove("method") {
        Some(Value::String(m)) if !m.is_empty() => m,
        _ => {
            return Some(Incoming::Invalid {
                id: if id_valid { id.unwrap_or(Value::Null) } else { Value::Null },
                error: RpcError::new(INVALID_REQUEST, "Invalid request: missing method"),
            });
        }
    };
    if !id_valid {
        return Some(Incoming::Invalid {
            id: Value::Null,
            error: RpcError::new(INVALID_REQUEST, "Invalid request: bad id"),
        });
    }
    let params = match obj.remove("params") {
        None | Some(Value::Null) => Value::Object(Map::new()),
        Some(p @ Value::Object(_)) => p,
        Some(_) => {
            return Some(match id {
                Some(id) => Incoming::Invalid {
                    id,
                    error: RpcError::invalid_params("params must be an object"),
                },
                None => return None,
            });
        }
    };
    Some(match id {
        Some(id) => Incoming::Request { id, method, params },
        None => Incoming::Notification { method, params },
    })
}

pub fn response_ok(id: &Value, result: Value) -> String {
    json!({"jsonrpc": "2.0", "result": result, "id": id}).to_string()
}

pub fn response_err(id: &Value, error: &RpcError) -> String {
    json!({"jsonrpc": "2.0", "error": error.to_json(), "id": id}).to_string()
}

pub fn notification(method: &str, params: Value) -> String {
    json!({"jsonrpc": "2.0", "method": method, "params": params}).to_string()
}

struct OutLine {
    line: String,
    written: Option<oneshot::Sender<()>>,
}

/// The single stdout writer. Cloneable handle.
#[derive(Clone)]
pub struct Output {
    tx: mpsc::UnboundedSender<OutLine>,
}

impl Output {
    /// Spawns the writer task on the current `LocalSet`.
    pub fn spawn<W: AsyncWrite + Unpin + 'static>(mut writer: W) -> (Self, tokio::task::JoinHandle<()>) {
        let (tx, mut rx) = mpsc::unbounded_channel::<OutLine>();
        let handle = tokio::task::spawn_local(async move {
            while let Some(OutLine { mut line, written }) = rx.recv().await {
                line.push('\n');
                let ok = writer.write_all(line.as_bytes()).await.is_ok()
                    && writer.flush().await.is_ok();
                if !ok {
                    tracing::warn!("stdout closed");
                }
                if let Some(done) = written {
                    if ok {
                        let _ = done.send(());
                    }
                }
            }
            let _ = writer.flush().await;
        });
        (Self { tx }, handle)
    }

    pub fn send(&self, line: String) {
        let _ = self.tx.send(OutLine {
            line,
            written: None,
        });
    }

    /// Writes a line and waits until it was flushed to stdout. False if it could not be written.
    pub async fn send_and_wait(&self, line: String) -> bool {
        let (done, wait) = oneshot::channel();
        if self
            .tx
            .send(OutLine {
                line,
                written: Some(done),
            })
            .is_err()
        {
            return false;
        }
        wait.await.is_ok()
    }
}

pub type HandlerFuture = Pin<Box<dyn Future<Output = Result<Value, RpcError>>>>;
pub type Handler = fn(Rc<Ctx>, Value) -> HandlerFuture;

/// One entry of a dispatch table.
pub struct Method {
    pub name: &'static str,
    pub handler: Handler,
}

/// Declares a dispatch table entry: `method!("send", messaging::send)` where `send` is an
/// `async fn(Rc<Ctx>, Value) -> Result<Value, RpcError>`.
#[macro_export]
macro_rules! method {
    ($name:literal, $f:path) => {
        $crate::rpc::Method {
            name: $name,
            handler: |ctx, params| Box::pin($f(ctx, params)),
        }
    };
}

pub struct Dispatcher {
    methods: HashMap<&'static str, Handler>,
}

impl Dispatcher {
    pub fn new(tables: &[&[Method]]) -> Self {
        let mut methods = HashMap::new();
        for table in tables {
            for m in table.iter() {
                let previous = methods.insert(m.name, m.handler);
                assert!(previous.is_none(), "method {} registered twice", m.name);
            }
        }
        Self { methods }
    }

    #[cfg(test)]
    pub fn names(&self) -> Vec<&'static str> {
        let mut names: Vec<_> = self.methods.keys().copied().collect();
        names.sort_unstable();
        names
    }

    pub async fn call(&self, ctx: Rc<Ctx>, method: &str, params: Value) -> Result<Value, RpcError> {
        match self.methods.get(method) {
            Some(handler) => handler(ctx, params).await,
            None => Err(RpcError::method_not_found(method)),
        }
    }
}

/// Handles one parsed line: spawns the request on the local set and writes its response.
pub fn handle_incoming(ctx: &Rc<Ctx>, dispatcher: &Rc<Dispatcher>, incoming: Incoming) {
    match incoming {
        Incoming::Invalid { id, error } => ctx.out.send(response_err(&id, &error)),
        Incoming::Request { id, method, params } => {
            let ctx = ctx.clone();
            let dispatcher = dispatcher.clone();
            tokio::task::spawn_local(async move {
                let started = std::time::Instant::now();
                let result = dispatcher.call(ctx.clone(), &method, params).await;
                let line = match &result {
                    Ok(value) => response_ok(&id, value.clone()),
                    Err(error) => {
                        tracing::info!(method, code = error.code, "request failed");
                        response_err(&id, error)
                    }
                };
                tracing::debug!(method, ms = started.elapsed().as_millis() as u64, "request done");
                ctx.out.send(line);
            });
        }
        Incoming::Notification { method, params } => {
            let ctx = ctx.clone();
            let dispatcher = dispatcher.clone();
            tokio::task::spawn_local(async move {
                let _ = dispatcher.call(ctx, &method, params).await;
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_request() {
        let r = parse_line(r#"{"jsonrpc":"2.0","method":"send","id":7,"params":{"message":"a\/b"}}"#);
        assert_eq!(
            r,
            Some(Incoming::Request {
                id: json!(7),
                method: "send".into(),
                params: json!({"message": "a/b"})
            })
        );
    }

    #[test]
    fn request_without_params_gets_empty_object() {
        let r = parse_line(" {\"jsonrpc\":\"2.0\",\"method\":\"listContacts\",\"id\":1}\r");
        assert_eq!(
            r,
            Some(Incoming::Request {
                id: json!(1),
                method: "listContacts".into(),
                params: json!({})
            })
        );
    }

    #[test]
    fn blank_lines_are_skipped() {
        assert_eq!(parse_line(""), None);
        assert_eq!(parse_line("   \r"), None);
    }

    #[test]
    fn garbage_is_a_parse_error_with_null_id() {
        match parse_line("not json") {
            Some(Incoming::Invalid { id, error }) => {
                assert_eq!(id, Value::Null);
                assert_eq!(error.code, PARSE_ERROR);
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn missing_method_keeps_id() {
        match parse_line(r#"{"jsonrpc":"2.0","id":3}"#) {
            Some(Incoming::Invalid { id, error }) => {
                assert_eq!(id, json!(3));
                assert_eq!(error.code, INVALID_REQUEST);
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn string_and_large_ids_are_echoed() {
        let r = parse_line(r#"{"jsonrpc":"2.0","method":"x","id":"abc"}"#);
        assert!(matches!(r, Some(Incoming::Request { id: Value::String(_), .. })));
        let r = parse_line(r#"{"jsonrpc":"2.0","method":"x","id":9007199254740993}"#).unwrap();
        let Incoming::Request { id, .. } = r else { panic!() };
        assert!(response_ok(&id, json!(null)).contains(r#""id":9007199254740993"#));
    }

    #[test]
    fn response_shapes() {
        let ok: Value = serde_json::from_str(&response_ok(&json!(5), json!({"timestamp": 1}))).unwrap();
        assert_eq!(ok["id"], 5);
        assert_eq!(ok["result"]["timestamp"], 1);
        assert!(ok.get("method").is_none());
        assert!(ok.get("error").is_none());
        let err: Value =
            serde_json::from_str(&response_err(&json!(6), &RpcError::failed("nope"))).unwrap();
        assert_eq!(err["id"], 6);
        assert_eq!(err["error"]["message"], "nope");
        assert_eq!(err["error"]["code"], FAILURE);
        assert!(err.get("result").is_none());
        let n: Value = serde_json::from_str(&notification("receive", json!({"envelope": {}}))).unwrap();
        assert_eq!(n["method"], "receive");
        assert!(n.get("id").is_none());
    }


    #[test]
    #[should_panic(expected = "registered twice")]
    fn duplicate_methods_are_rejected() {
        async fn noop(_: Rc<Ctx>, _: Value) -> Result<Value, RpcError> {
            Ok(Value::Null)
        }
        let table: &[Method] = &[crate::method!("a", noop), crate::method!("a", noop)];
        Dispatcher::new(&[table]);
    }
}
