//! listContacts, updateContact, removeContact, block, unblock, sendMessageRequestResponse, getAvatar.

use std::collections::BTreeMap;
use std::rc::Rc;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as B64;
use presage::libsignal_service::content::ContentBody;
use presage::libsignal_service::prelude::Uuid;
use presage::proto::{DataMessage, SyncMessage, data_message, sync_message};
use serde_json::{Value, json};

use super::common::*;
use super::storage;
use crate::avatars;
use crate::ctx::{Account, Ctx, now_millis};
use crate::method;
use crate::rpc::{Method, RpcError, fail};

pub const METHODS: &[Method] = &[
    method!("listContacts", list_contacts),
    method!("updateContact", update_contact),
    method!("removeContact", remove_contact),
    method!("block", block),
    method!("unblock", unblock),
    method!("sendMessageRequestResponse", message_request_response),
    method!("getAvatar", get_avatar),
];

async fn list_contacts(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    let a = ctx.account()?;
    let wanted: Vec<Uuid> = {
        let mut v = Vec::new();
        for r in strs_param(&p, "recipients").into_iter().chain(strs_param(&p, "recipient")) {
            v.push(a.resolve_aci(&r).await?);
        }
        v
    };
    let mut entries: BTreeMap<Uuid, Value> = BTreeMap::new();
    let mut uuids: Vec<Uuid> = Vec::new();
    for c in a.contacts().await? {
        uuids.push(c.uuid);
    }
    for (uuid, _) in a.local().all_contacts().await {
        uuids.push(uuid);
    }
    uuids.push(a.aci);
    uuids.sort();
    uuids.dedup();
    for uuid in uuids {
        if !wanted.is_empty() && !wanted.contains(&uuid) {
            continue;
        }
        entries.insert(uuid, contact_json(a, &uuid).await);
    }
    Ok(Value::Array(entries.into_values().collect()))
}

pub async fn contact_json(a: &Account, uuid: &Uuid) -> Value {
    let stored = a.contact(uuid).await;
    let local = a.local().contact(uuid).await;
    let number = a.number_of(uuid).await;
    let profile = a.cached_profile(uuid).await;
    let profile_name = a.profile_name(uuid).await;
    let address_book = stored.as_ref().map(|c| c.name.clone()).unwrap_or_default();
    let name = if !local.given_name.is_empty() || !local.family_name.is_empty() {
        format!("{} {}", local.given_name, local.family_name).trim().to_string()
    } else {
        address_book
    };
    let expiration = stored.as_ref().map(|c| c.expire_timer).unwrap_or(0);
    let mut o = json!({
        "number": number,
        "uuid": uuid.to_string(),
        "name": name,
        "givenName": local.given_name,
        "familyName": local.family_name,
        "nickGivenName": local.nick_given_name,
        "nickFamilyName": local.nick_family_name,
        "note": local.note,
        "profileName": profile_name,
        "isBlocked": local.blocked,
        "isHidden": local.hidden,
        "isArchived": local.archived,
        "messageExpirationTime": expiration,
    });
    if let Some(profile) = profile {
        let (given, family) = match &profile.name {
            Some(n) => (n.given_name.clone(), n.family_name.clone().unwrap_or_default()),
            None => (String::new(), String::new()),
        };
        o["profile"] = json!({
            "givenName": given,
            "familyName": family,
            "about": profile.about.unwrap_or_default(),
            "aboutEmoji": profile.about_emoji.unwrap_or_default(),
            "hasAvatar": profile.avatar.is_some_and(|s| !s.is_empty()),
        });
    }
    if *uuid == a.aci {
        if let Some(u) = a.local().own_username().await {
            o["username"] = json!(u);
        }
    }
    o
}

async fn update_contact(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    let a = ctx.account()?;
    let who = req_str(&p, "recipient")?;
    let uuid = a.resolve_aci(&who).await?;
    if let Some(seconds) = i64_param(&p, "expiration") {
        set_expiration(a, &Target::Contacts(vec![a.resolve(&who).await?]), seconds.max(0) as u32).await?;
    }
    let mut changed = false;
    a.local()
        .update_contact(&uuid, |c| {
            for (key, field) in [
                ("nickGivenName", &mut c.nick_given_name),
                ("nickFamilyName", &mut c.nick_family_name),
                ("note", &mut c.note),
                ("givenName", &mut c.given_name),
                ("familyName", &mut c.family_name),
            ] {
                if let Some(v) = str_param(&p, key) {
                    *field = v;
                    changed = true;
                }
            }
            if let Some(name) = str_param(&p, "name") {
                c.given_name = name;
                c.family_name.clear();
                changed = true;
            }
        })
        .await
        .map_err(fail)?;
    if changed {
        a.invalidate_directory();
        storage::contact_changed(a, &uuid).await;
    }
    Ok(json!({}))
}

/// Sends an expiration timer update, which also sets the timer locally.
pub async fn set_expiration(a: &Account, target: &Target, seconds: u32) -> Result<Value, RpcError> {
    let timestamp = now_millis();
    let dm = DataMessage {
        timestamp: Some(timestamp),
        group_v2: target.group_context(),
        flags: Some(data_message::Flags::ExpirationTimerUpdate as u32),
        expire_timer: Some(seconds),
        ..Default::default()
    };
    deliver(a, target, ContentBody::DataMessage(dm), timestamp, false).await
}

async fn remove_contact(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    let a = ctx.account()?;
    let uuid = a.resolve_aci(&req_str(&p, "recipient")?).await?;
    a.local().update_contact(&uuid, |c| c.hidden = false).await.map_err(fail)?;
    storage::contact_changed(a, &uuid).await;
    Ok(json!({}))
}

async fn block(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    set_blocked(&ctx, &p, true).await
}

async fn unblock(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    set_blocked(&ctx, &p, false).await
}

async fn set_blocked(ctx: &Ctx, p: &Value, blocked: bool) -> Result<Value, RpcError> {
    let a = ctx.account()?;
    // Storage Service plus the blocked-list sync; if the Storage Service is unreachable, the local
    // change still stands and a plain blocked-list sync tells the other devices.
    let mut fallback = false;
    for r in strs_param(p, "recipient") {
        let uuid = a.resolve_aci(&r).await?;
        if let Err(e) = storage::set_contact_blocked(a, &uuid, blocked).await {
            tracing::info!("storage block failed: {}", e.message);
            fallback = true;
        }
    }
    for g in strs_param(p, "groupId") {
        let (master_key, _) = a.group_by_id(&g).await?;
        if let Err(e) = storage::set_group_blocked(a, &g, master_key, blocked).await {
            tracing::info!("storage block failed: {}", e.message);
            fallback = true;
        }
    }
    if fallback {
        send_blocked_sync(a).await;
    }
    Ok(json!({}))
}

/// Tells our other devices the full blocked list (as Signal clients do after every change).
pub async fn send_blocked_sync(a: &Account) {
    let mut acis = Vec::new();
    let mut numbers = Vec::new();
    for (uuid, c) in a.local().all_contacts().await {
        if c.blocked {
            acis.push(uuid.to_string());
            if let Some(n) = a.number_of(&uuid).await {
                numbers.push(n);
            }
        }
    }
    let mut group_ids = Vec::new();
    for g in a.local().blocked_groups().await {
        if let Ok(bytes) = decode_group_id(&g) {
            group_ids.push(bytes);
        }
    }
    let sync = SyncMessage {
        content: Some(sync_message::Content::Blocked(sync_message::Blocked {
            numbers,
            acis,
            group_ids,
            ..Default::default()
        })),
        ..Default::default()
    };
    let target = Target::Contacts(vec![a.own_service_id()]);
    if let Err(e) = deliver(a, &target, ContentBody::SynchronizeMessage(sync), now_millis(), false).await {
        tracing::info!("blocked sync failed: {}", e.message);
    }
}

async fn message_request_response(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    let a = ctx.account()?;
    let kind = req_str(&p, "type")?.to_ascii_lowercase();
    use sync_message::message_request_response::Type;
    let t = match kind.as_str() {
        "accept" => Type::Accept,
        "delete" => Type::Delete,
        "block" => Type::Block,
        "block_and_delete" | "blockanddelete" => Type::BlockAndDelete,
        "spam" => Type::Spam,
        _ => return Err(RpcError::invalid_params(format!("Unknown message request response type {kind}"))),
    };
    let target = Target::from_params(a, &p).await?;
    let mut mrr = sync_message::MessageRequestResponse {
        r#type: Some(t as i32),
        ..Default::default()
    };
    match &target {
        Target::Group { master_key, .. } => {
            mrr.group_id = crate::envelope::group_id_from_master_key(master_key)
                .and_then(|g| B64.decode(g).ok());
        }
        Target::Contacts(ids) => {
            let id = ids.first().ok_or_else(|| RpcError::invalid_params("missing recipient"))?;
            mrr.thread_aci = Some(id.service_id_string());
            if let presage::libsignal_service::protocol::ServiceId::Aci(aci) = id {
                let uuid: Uuid = (*aci).into();
                a.local()
                    .update_contact(&uuid, |c| {
                        c.hidden = false;
                        if matches!(t, Type::Block | Type::BlockAndDelete) {
                            c.blocked = true;
                        }
                    })
                    .await
                    .map_err(fail)?;
            }
        }
    }
    if t == Type::Accept {
        // Share our profile key so the other side sees our name, as the apps do on accept.
        let timestamp = now_millis();
        let dm = DataMessage {
            timestamp: Some(timestamp),
            group_v2: target.group_context(),
            flags: Some(data_message::Flags::ProfileKeyUpdate as u32),
            ..Default::default()
        };
        if let Err(e) = deliver(a, &target, ContentBody::DataMessage(dm), timestamp, false).await {
            tracing::info!("profile key share failed: {}", e.message);
        }
    }
    let sync = SyncMessage {
        content: Some(sync_message::Content::MessageRequestResponse(mrr)),
        ..Default::default()
    };
    let own = Target::Contacts(vec![a.own_service_id()]);
    deliver(a, &own, ContentBody::SynchronizeMessage(sync), now_millis(), false).await?;
    Ok(json!({}))
}

async fn get_avatar(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    let a = ctx.account()?;
    let bytes = if let Some(g) = str_param(&p, "groupId") {
        let (key, group) = a.group_by_id(&g).await?;
        avatars::group_avatar(a, &ctx.dir, &key, group.revision).await?
    } else if let Some(c) = str_param(&p, "contact") {
        let uuid = a.resolve_aci(&c).await?;
        avatars::contact_avatar(a, &ctx.dir, &uuid).await
    } else if let Some(pr) = str_param(&p, "profile") {
        let uuid = a.resolve_aci(&pr).await?;
        avatars::profile_avatar(a, &ctx.dir, &uuid, true).await?
    } else {
        return Err(RpcError::invalid_params("one of groupId, contact or profile is required"));
    };
    match bytes {
        Some(b) if !b.is_empty() => Ok(json!({"data": B64.encode(b)})),
        _ => Err(RpcError::failed("No avatar")),
    }
}
