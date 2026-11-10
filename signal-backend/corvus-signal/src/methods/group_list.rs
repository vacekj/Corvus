//! listGroups.

use std::rc::Rc;

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use presage::libsignal_service::groups_v2::{AccessRequired, Role};
use presage::libsignal_service::prelude::Uuid;
use presage::model::groups::Group;
use presage::proto::{GroupInviteLink, group_invite_link};
use prost::Message as _;
use serde_json::{Value, json};

use super::common::*;
use crate::ctx::{Account, Ctx, normalize_group_id};
use crate::envelope::group_id_from_master_key;
use crate::method;
use crate::rpc::{Method, RpcError};

pub const METHODS: &[Method] = &[method!("listGroups", list_groups)];

async fn list_groups(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    let a = ctx.account()?;
    let wanted: Vec<String> = strs_param(&p, "groupId").iter().map(|g| normalize_group_id(g)).collect();
    let mut out = Vec::new();
    for (key, group) in a.groups().await? {
        let Some(id) = group_id_from_master_key(&key) else { continue };
        if !wanted.is_empty() && !wanted.contains(&id) {
            continue;
        }
        out.push(group_json(a, &id, &key, &group).await);
    }
    Ok(Value::Array(out))
}

pub async fn group_json(a: &Account, id: &str, master_key: &[u8; 32], g: &Group) -> Value {
    let me = a.aci;
    let mut members = Vec::new();
    let mut admins = Vec::new();
    for m in &g.members {
        let uuid: Uuid = m.aci.into();
        let is_admin = m.role == Role::Administrator;
        let mut o = person(a, &uuid).await;
        o["isAdmin"] = json!(is_admin);
        o["label"] = json!(m.label.clone().unwrap_or_default());
        o["labelEmoji"] = json!(m.label_emoji.clone().unwrap_or_default());
        if is_admin {
            admins.push(person(a, &uuid).await);
        }
        members.push(o);
    }
    let mut pending = Vec::new();
    for m in &g.pending_members {
        pending.push(person(a, &m.uuid).await);
    }
    let mut requesting = Vec::new();
    for m in &g.requesting_members {
        requesting.push(person(a, &m.aci.into()).await);
    }
    let mut banned = Vec::new();
    for b in &g.banned_members {
        banned.push(person(a, &b.uuid).await);
    }
    let is_member = g.members.iter().any(|m| Uuid::from(m.aci) == me);
    let permission = |r: Option<AccessRequired>| match r {
        Some(AccessRequired::Administrator) => "ONLY_ADMINS",
        _ => "EVERY_MEMBER",
    };
    let ac = g.access_control.as_ref();
    let link_enabled = ac.is_some_and(|ac| {
        matches!(ac.add_from_invite_link, AccessRequired::Any | AccessRequired::Administrator)
    }) && !g.invite_link_password.is_empty();
    let link = if link_enabled { invite_link(master_key, &g.invite_link_password) } else { String::new() };
    json!({
        "id": id,
        "name": g.title,
        "description": g.description.clone().unwrap_or_default(),
        "isMember": is_member,
        "isBlocked": a.local().group_blocked(id).await,
        "isArchived": a
            .local()
            .value::<Vec<String>>(super::storage::ARCHIVED_GROUPS)
            .await
            .contains(&normalize_group_id(id)),
        "isTerminated": g.terminated,
        "messageExpirationTime": g.disappearing_messages_timer.as_ref().map(|t| t.duration).unwrap_or(0),
        "members": members,
        "pendingMembers": pending,
        "requestingMembers": requesting,
        "banned": banned,
        "admins": admins,
        "permissionAddMember": permission(ac.map(|a| a.members)),
        "permissionEditDetails": permission(ac.map(|a| a.attributes)),
        "permissionSendMessage": if g.announcements_only { "ONLY_ADMINS" } else { "EVERY_MEMBER" },
        "groupInviteLink": link,
        "linkRequiresApproval": ac.is_some_and(|ac| ac.add_from_invite_link == AccessRequired::Administrator),
        "revision": g.revision,
    })
}

async fn person(a: &Account, uuid: &Uuid) -> Value {
    json!({"number": a.number_of(uuid).await, "uuid": uuid.to_string()})
}

pub fn invite_link(master_key: &[u8; 32], password: &[u8]) -> String {
    let link = GroupInviteLink {
        contents: Some(group_invite_link::Contents::ContentsV1(
            group_invite_link::GroupInviteLinkContentsV1 {
                group_master_key: master_key.to_vec(),
                invite_link_password: password.to_vec(),
            },
        )),
    };
    format!("https://signal.group/#{}", URL_SAFE_NO_PAD.encode(link.encode_to_vec()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn invite_link_roundtrip() {
        let key = [7u8; 32];
        let link = invite_link(&key, b"secret-pass");
        assert!(link.starts_with("https://signal.group/#"));
        let parsed = presage::libsignal_service::groups_v2::GroupInviteLink::parse(&link).unwrap();
        assert_eq!(parsed.master_key, key);
        assert_eq!(parsed.password, b"secret-pass");
    }
}
