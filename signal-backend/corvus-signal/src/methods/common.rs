//! Parameter parsing and message delivery shared by the method files.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as B64;
use presage::libsignal_service::content::ContentBody;
use presage::libsignal_service::sender::SenderKeyState;
use presage::proto::{DataMessage, EditMessage};
use prost::Message as _;
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
    let logged = if online_only { None } else { sent_log_entry(target, &body) };
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
            let started = std::time::Instant::now();
            // With our sender key (typing indicators too): one request for the members that allow it.
            let (mut state, members) = sender_key_state(a, master_key).await;
            let rs = mgr
                .send_message_to_group_sender_key(master_key, body, timestamp, online_only, Some(&mut state))
                .await
                .map_err(fail)?;
            keep_sender_key_state(a, master_key, state, members).await;
            if !online_only {
                tracing::info!(recipients = rs.len(), ms = started.elapsed().as_millis() as u64, "group message sent");
            }
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
    if let Some(entry) = logged {
        a.local().log_sent(timestamp, &entry).await;
    }
    Ok(json!({"timestamp": timestamp, "results": results}))
}

/// Our sender key state for a group and its current members. Someone who left must not be able to
/// read what follows: then a new key (a new distribution id) that only the current members get.
async fn sender_key_state(a: &Account, master_key: &[u8; 32]) -> (SenderKeyState, Vec<String>) {
    let members: Vec<String> = a
        .groups()
        .await
        .unwrap_or_default()
        .into_iter()
        .find(|(k, _)| k == master_key)
        .map(|(_, g)| g.members.iter().map(|m| ServiceId::from(m.aci).service_id_string()).collect())
        .unwrap_or_default();
    let record = a.local().sender_key(&B64.encode(master_key)).await;
    let state = record.and_then(|r| {
        let kept = r.members.iter().all(|m| members.contains(m));
        let id = r.distribution_id.parse().ok()?;
        kept.then(|| SenderKeyState { distribution_id: id, shared: r.shared.into_iter().collect() })
    });
    let state = state.unwrap_or_else(|| SenderKeyState {
        distribution_id: uuid::Builder::from_random_bytes(rand::random()).into_uuid(),
        shared: Default::default(),
    });
    (state, members)
}

async fn keep_sender_key_state(a: &Account, master_key: &[u8; 32], state: SenderKeyState, members: Vec<String>) {
    let record = crate::store::SenderKeyRecord {
        distribution_id: state.distribution_id.to_string(),
        shared: state.shared.into_iter().collect(),
        members,
    };
    if let Err(error) = a.local().set_sender_key(&B64.encode(master_key), &record).await {
        tracing::warn!(%error, "could not keep the group's sender key state");
    }
}

/// The user started typing in a group: the members that lack our sender key get it now, so the
/// message goes out in one request. At most every few minutes per group.
pub async fn prepare_group_send(a: &Account, master_key: &[u8; 32]) {
    if !a.first_prepare(master_key) {
        return;
    }
    let (mut state, members) = sender_key_state(a, master_key).await;
    match a.manager().prepare_group_sender_key(master_key, &mut state).await {
        Ok(missed) if missed > 0 => tracing::info!(missed, "sender key not delivered to every member"),
        Ok(_) => {}
        Err(error) => tracing::info!(%error, "sender key not prepared"),
    }
    keep_sender_key_state(a, master_key, state, members).await;
}

/// What the send log keeps of a message: messages people see (not receipts, typing and the like).
fn sent_log_entry(target: &Target, body: &ContentBody) -> Option<crate::store::SentLogEntry> {
    let (kind, bytes) = match body {
        ContentBody::DataMessage(dm) => ("data", dm.encode_to_vec()),
        ContentBody::EditMessage(em) => ("edit", em.encode_to_vec()),
        _ => return None,
    };
    let (group, recipients) = match target {
        Target::Contacts(ids) => (None, ids.iter().map(|id| id.service_id_string()).collect()),
        Target::Group { master_key, .. } => (Some(B64.encode(master_key)), Vec::new()),
    };
    Some(crate::store::SentLogEntry { kind: kind.into(), body: B64.encode(bytes), group, recipients })
}

/// `requester` could not decrypt our message sent at `timestamp` and asked for it again (the session
/// was already replaced): sends it again to them, once per run, if the send log still has it and they
/// were one of its recipients.
pub async fn resend_logged(a: &Account, requester: ServiceId, timestamp: u64) {
    // They may be missing our sender key: it goes to them again with the next group message.
    a.local().forget_sender_key_member(&requester.service_id_string()).await;
    if !a.first_resend(&requester, timestamp) {
        return;
    }
    let Some(entry) = a.local().sent(timestamp).await else {
        tracing::info!("asked again for a message that is no longer kept");
        return;
    };
    let recipient = match &entry.group {
        Some(key) => {
            let key: Option<[u8; 32]> = B64.decode(key).ok().and_then(|k| k.try_into().ok());
            let groups = a.groups().await.unwrap_or_default();
            key.and_then(|key| groups.into_iter().find(|(k, _)| *k == key))
                .is_some_and(|(_, g)| g.members.iter().any(|m| ServiceId::from(m.aci) == requester))
        }
        None => entry.recipients.contains(&requester.service_id_string()),
    };
    if !recipient {
        tracing::warn!("asked again for a message by someone it was not sent to");
        return;
    }
    let Ok(bytes) = B64.decode(&entry.body) else { return };
    let body = match entry.kind.as_str() {
        "data" => DataMessage::decode(bytes.as_slice()).ok().map(ContentBody::DataMessage),
        "edit" => EditMessage::decode(bytes.as_slice()).ok().map(ContentBody::EditMessage),
        _ => None,
    };
    let Some(body) = body else { return };
    match a.manager().resend_message(requester, body, timestamp).await {
        Ok(()) => tracing::info!("message sent again after a retry request"),
        Err(error) => tracing::warn!(%error, "could not send a message again after a retry request"),
    }
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

    #[test]
    fn send_log_keeps_what_people_see() {
        let id = ServiceId::parse_from_service_id_string("00000000-0000-4000-8000-000000000001").unwrap();
        let dm = DataMessage { body: Some("hi".into()), timestamp: Some(5), ..Default::default() };
        let entry = sent_log_entry(&Target::Contacts(vec![id]), &ContentBody::DataMessage(dm.clone())).unwrap();
        assert_eq!(entry.kind, "data");
        assert_eq!(entry.recipients, vec![id.service_id_string()]);
        assert_eq!(DataMessage::decode(B64.decode(&entry.body).unwrap().as_slice()).unwrap(), dm);
        let json = serde_json::to_vec(&entry).unwrap();
        assert_eq!(serde_json::from_slice::<crate::store::SentLogEntry>(&json).unwrap(), entry);

        let group = Target::Group { master_key: [7; 32], revision: 0 };
        let entry = sent_log_entry(&group, &ContentBody::DataMessage(dm)).unwrap();
        assert_eq!(entry.group.as_deref(), Some(B64.encode([7u8; 32]).as_str()));
        assert!(entry.recipients.is_empty());

        let typing = ContentBody::TypingMessage(Default::default());
        assert!(sent_log_entry(&group, &typing).is_none());
    }
}
