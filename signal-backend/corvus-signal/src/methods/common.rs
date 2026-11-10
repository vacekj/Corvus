//! Parameter parsing and message delivery shared by the method files.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as B64;
use presage::libsignal_service::content::ContentBody;
use presage::libsignal_service::protocol::ServiceId;
use presage::proto::GroupContextV2;
use serde_json::{Value, json};

use crate::ctx::{Account, normalize_group_id};
use crate::envelope::group_id_from_master_key;
use crate::rpc::{RpcError, fail};

pub fn str_param(p: &Value, key: &str) -> Option<String> {
    match p.get(key)? {
        Value::String(s) => Some(s.clone()),
        Value::Array(a) => a.first()?.as_str().map(str::to_owned),
        _ => None,
    }
}

pub fn req_str(p: &Value, key: &str) -> Result<String, RpcError> {
    str_param(p, key)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| RpcError::invalid_params(format!("missing parameter {key}")))
}

/// A string or an array of strings.
pub fn strs_param(p: &Value, key: &str) -> Vec<String> {
    match p.get(key) {
        Some(Value::String(s)) => vec![s.clone()],
        Some(Value::Array(a)) => a.iter().filter_map(|v| v.as_str().map(str::to_owned)).collect(),
        _ => Vec::new(),
    }
}

pub fn i64_param(p: &Value, key: &str) -> Option<i64> {
    match p.get(key)? {
        Value::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)),
        Value::String(s) => s.parse().ok(),
        Value::Array(a) => a.first().and_then(|v| v.as_i64()),
        _ => None,
    }
}

pub fn req_u64(p: &Value, key: &str) -> Result<u64, RpcError> {
    i64_param(p, key)
        .filter(|v| *v > 0)
        .map(|v| v as u64)
        .ok_or_else(|| RpcError::invalid_params(format!("missing parameter {key}")))
}

pub fn i64s_param(p: &Value, key: &str) -> Vec<i64> {
    match p.get(key) {
        Some(Value::Array(a)) => a
            .iter()
            .filter_map(|v| v.as_i64().or_else(|| v.as_str().and_then(|s| s.trim().parse().ok())))
            .collect(),
        Some(v) => i64_param(&json!({ "v": v }), "v").into_iter().collect(),
        None => Vec::new(),
    }
}

pub fn bool_param(p: &Value, key: &str) -> bool {
    match p.get(key) {
        Some(Value::Bool(b)) => *b,
        Some(Value::String(s)) => s == "true",
        Some(Value::Number(n)) => n.as_i64().unwrap_or(0) != 0,
        _ => false,
    }
}

/// Where a message goes.
pub enum Target {
    Contacts(Vec<ServiceId>),
    Group { master_key: [u8; 32], revision: u32 },
}

impl Target {
    /// `groupId` (string or array) wins over `recipient` (string or array), as in signal-cli.
    pub async fn from_params(a: &Account, p: &Value) -> Result<Self, RpcError> {
        Self::from_keys(a, p, "recipient", "groupId").await
    }

    pub async fn from_keys(a: &Account, p: &Value, rkey: &str, gkey: &str) -> Result<Self, RpcError> {
        if let Some(gid) = str_param(p, gkey).filter(|s| !s.is_empty()) {
            let (master_key, group) = a.group_by_id(&gid).await?;
            return Ok(Target::Group {
                master_key,
                revision: group.revision,
            });
        }
        let ids = strs_param(p, rkey);
        if ids.is_empty() {
            return Err(RpcError::invalid_params(format!("missing parameter {rkey} or {gkey}")));
        }
        let mut out = Vec::with_capacity(ids.len());
        for id in ids {
            out.push(a.resolve(&id).await?);
        }
        Ok(Target::Contacts(out))
    }

    pub fn group_context(&self) -> Option<GroupContextV2> {
        match self {
            Target::Group { master_key, revision } => Some(GroupContextV2 {
                master_key: Some(master_key.to_vec()),
                revision: Some(*revision),
                group_change: None,
            }),
            Target::Contacts(_) => None,
        }
    }

    /// The group identifier bytes (what typing messages carry).
    pub fn group_id_bytes(&self) -> Option<Vec<u8>> {
        match self {
            Target::Group { master_key, .. } => {
                B64.decode(group_id_from_master_key(master_key)?).ok()
            }
            Target::Contacts(_) => None,
        }
    }
}

/// Sends `body` and returns signal-cli's `{timestamp, results}`. Errors only if nobody got it.
pub async fn deliver(
    a: &Account,
    target: &Target,
    body: ContentBody,
    timestamp: u64,
    online_only: bool,
) -> Result<Value, RpcError> {
    let mut mgr = a.manager();
    let mut results = Vec::new();
    let mut first_error: Option<String> = None;
    let mut delivered = 0usize;
    match target {
        Target::Contacts(ids) => {
            for id in ids {
                let r = mgr.send_message_ext(*id, body.clone(), timestamp, online_only).await;
                let number = match id {
                    ServiceId::Aci(aci) => a.number_of(&(*aci).into()).await,
                    ServiceId::Pni(_) => None,
                };
                let address = json!({"uuid": id.service_id_string(), "number": number});
                match r {
                    Ok(_) => {
                        delivered += 1;
                        results.push(json!({"recipientAddress": address, "type": "SUCCESS"}));
                    }
                    Err(e) => {
                        let msg = e.to_string();
                        first_error.get_or_insert_with(|| msg.clone());
                        results.push(json!({"recipientAddress": address, "type": failure_type(&msg), "message": msg}));
                    }
                }
            }
        }
        Target::Group { master_key, .. } => {
            let rs = mgr
                .send_message_to_group_ext(master_key, body, timestamp, online_only)
                .await
                .map_err(fail)?;
            for r in rs {
                match r {
                    Ok(sent) => {
                        delivered += 1;
                        results.push(json!({
                            "recipientAddress": {"uuid": sent.recipient.service_id_string()},
                            "type": "SUCCESS"
                        }));
                    }
                    Err(e) => {
                        let msg = e.to_string();
                        // A member who deleted their account is not a failure of the send.
                        if !msg.contains("not found") {
                            first_error.get_or_insert_with(|| msg.clone());
                        }
                        results.push(json!({"type": failure_type(&msg), "message": msg}));
                    }
                }
            }
            if delivered == 0 && first_error.is_none() {
                // A group with only us in it: nothing to deliver, still a success.
                delivered = 1;
            }
        }
    }
    if delivered == 0 {
        return Err(RpcError::failed(first_error.unwrap_or_else(|| "Failed to send message".into())));
    }
    Ok(json!({"timestamp": timestamp, "results": results}))
}

fn failure_type(msg: &str) -> &'static str {
    let m = msg.to_ascii_lowercase();
    if m.contains("untrusted") || m.contains("identity") {
        "IDENTITY_FAILURE"
    } else if m.contains("not found") || m.contains("unregistered") {
        "UNREGISTERED_FAILURE"
    } else if m.contains("rate") {
        "RATE_LIMIT_FAILURE"
    } else {
        "NETWORK_FAILURE"
    }
}

pub fn decode_group_id(id: &str) -> Result<Vec<u8>, RpcError> {
    B64.decode(normalize_group_id(id))
        .map_err(|_| RpcError::invalid_params(format!("Invalid group id: {id}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn params_helpers_accept_both_shapes() {
        let p = json!({"recipient": ["+1"], "groupId": "g", "ts": "12", "list": [1, "2"], "b": true});
        assert_eq!(str_param(&p, "recipient").as_deref(), Some("+1"));
        assert_eq!(strs_param(&p, "groupId"), vec!["g".to_string()]);
        assert_eq!(i64_param(&p, "ts"), Some(12));
        assert_eq!(i64s_param(&p, "list"), vec![1, 2]);
        assert!(bool_param(&p, "b"));
        assert!(!bool_param(&p, "missing"));
    }
}
