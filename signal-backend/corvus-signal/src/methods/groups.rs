//! updateGroup (create, change, accept an invitation), quitGroup, joinGroup.

use std::rc::Rc;

use presage::libsignal_service::groups_v2::{AccessRequired, GroupInviteLink};
use presage::libsignal_service::protocol::{Aci, ServiceId};
use presage::manager::{GroupJoinOutcome, GroupUpdate, InviteLinkAccess, MemberLabel, NewGroup};
use serde_json::{Value, json};

use super::common::*;
use crate::ctx::{Account, Ctx};
use crate::envelope::group_id_from_master_key;
use crate::method;
use crate::rpc::{Method, RpcError, fail};

pub const METHODS: &[Method] = &[
    method!("updateGroup", update_group),
    method!("quitGroup", quit_group),
    method!("joinGroup", join_group),
];

/// Keys that change a group; `{"groupId"}` with none of them accepts an invitation.
const CHANGE_KEYS: &[&str] = &[
    "name",
    "description",
    "member",
    "removeMember",
    "admin",
    "removeAdmin",
    "ban",
    "unban",
    "link",
    "resetLink",
    "avatar",
    "expiration",
    "setPermissionAddMember",
    "setPermissionEditDetails",
    "setPermissionSendMessages",
    "memberLabel",
    "memberLabelEmoji",
];

async fn service_ids(a: &Account, p: &Value, key: &str) -> Result<Vec<ServiceId>, RpcError> {
    let mut out = Vec::new();
    for id in strs_param(p, key) {
        out.push(a.resolve(&id).await?);
    }
    Ok(out)
}

async fn acis(a: &Account, p: &Value, key: &str) -> Result<Vec<Aci>, RpcError> {
    let mut out = Vec::new();
    for id in strs_param(p, key) {
        out.push(Aci::from(a.resolve_aci(&id).await?));
    }
    Ok(out)
}

fn access(p: &Value, key: &str) -> Result<Option<AccessRequired>, RpcError> {
    match str_param(p, key).as_deref().map(str::to_ascii_lowercase).as_deref() {
        None => Ok(None),
        Some("only-admins" | "onlyadmins" | "only_admins") => Ok(Some(AccessRequired::Administrator)),
        Some("every-member" | "everymember" | "every_member") => Ok(Some(AccessRequired::Member)),
        Some(other) => Err(RpcError::invalid_params(format!("unknown permission {other}"))),
    }
}

fn read_avatar(p: &Value) -> Result<Option<Vec<u8>>, RpcError> {
    match str_param(p, "avatar").filter(|s| !s.is_empty()) {
        Some(path) => std::fs::read(&path)
            .map(Some)
            .map_err(|e| RpcError::failed(format!("Cannot read {path}: {e}"))),
        None => Ok(None),
    }
}

async fn update_group(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    let a = ctx.account()?;
    let Some(group_id) = str_param(&p, "groupId").filter(|s| !s.is_empty()) else {
        return create_group(a, &p).await;
    };
    let (master_key, group) = a.group_by_id(&group_id).await?;
    let mut mgr = a.manager();

    let has_change = p.as_object().is_some_and(|o| o.keys().any(|k| CHANGE_KEYS.contains(&k.as_str())));
    if !has_change {
        let is_member = group.members.iter().any(|m| m.aci == Aci::from(a.aci));
        if !is_member {
            mgr.accept_group_invitation(master_key).await.map_err(fail)?;
        }
        return Ok(json!({}));
    }

    let link = match str_param(&p, "link").as_deref() {
        None => None,
        Some("disabled") => Some(InviteLinkAccess::Disabled),
        Some("enabled") => Some(InviteLinkAccess::Open),
        Some("enabled-with-approval") => Some(InviteLinkAccess::AdminApproval),
        Some(other) => return Err(RpcError::invalid_params(format!("unknown link mode {other}"))),
    };
    let own_member_label = match (str_param(&p, "memberLabel"), str_param(&p, "memberLabelEmoji")) {
        (None, None) => None,
        (label, emoji) => Some(MemberLabel {
            label: label.unwrap_or_default(),
            emoji: emoji.unwrap_or_default(),
        }),
    };
    let update = GroupUpdate {
        title: str_param(&p, "name").filter(|s| !s.trim().is_empty()),
        description: str_param(&p, "description"),
        avatar: read_avatar(&p)?,
        disappearing_messages_timer: i64_param(&p, "expiration").map(|s| s.max(0) as u32),
        attributes_access: access(&p, "setPermissionEditDetails")?,
        members_access: access(&p, "setPermissionAddMember")?,
        member_label_access: None,
        announcements_only: str_param(&p, "setPermissionSendMessages")
            .map(|v| matches!(v.to_ascii_lowercase().as_str(), "only-admins" | "onlyadmins" | "only_admins")),
        invite_link: link,
        reset_invite_link: bool_param(&p, "resetLink"),
        add_members: service_ids(a, &p, "member").await?,
        remove_members: service_ids(a, &p, "removeMember").await?,
        make_admins: acis(a, &p, "admin").await?,
        revoke_admins: acis(a, &p, "removeAdmin").await?,
        ban: service_ids(a, &p, "ban").await?,
        unban: service_ids(a, &p, "unban").await?,
        own_member_label,
    };
    let outcome = mgr.update_group(master_key, update).await.map_err(fail)?;
    if let Some(ts) = outcome.timestamp {
        Ok(json!({"groupId": group_id, "timestamp": ts, "revision": outcome.revision}))
    } else {
        Ok(json!({"groupId": group_id, "revision": outcome.revision}))
    }
}

async fn create_group(a: &Account, p: &Value) -> Result<Value, RpcError> {
    let title = str_param(p, "name").filter(|s| !s.trim().is_empty());
    let Some(title) = title else {
        return Err(RpcError::invalid_params("A new group needs a name"));
    };
    let new = NewGroup {
        title,
        description: str_param(p, "description").filter(|s| !s.is_empty()),
        members: service_ids(a, p, "member").await?,
        avatar: read_avatar(p)?,
        disappearing_messages_timer: i64_param(p, "expiration").unwrap_or(0).max(0) as u32,
    };
    let created = a.manager().create_group(new).await.map_err(fail)?;
    let id = group_id_from_master_key(&created.master_key).unwrap_or_default();
    Ok(json!({"groupId": id, "timestamp": created.timestamp}))
}

async fn quit_group(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    let a = ctx.account()?;
    let (master_key, _) = a.group_by_id(&req_str(&p, "groupId")?).await?;
    let successors = acis(a, &p, "admin").await?;
    a.manager().leave_group(master_key, &successors).await.map_err(fail)?;
    Ok(json!({}))
}

async fn join_group(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    let a = ctx.account()?;
    let uri = req_str(&p, "uri")?;
    let link = GroupInviteLink::parse(&uri).ok_or_else(|| RpcError::invalid_params("Not a group invite link"))?;
    let id = group_id_from_master_key(&link.master_key).unwrap_or_default();
    let only_requested = match a.manager().join_group_via_link(&link).await.map_err(fail)? {
        GroupJoinOutcome::Requested { .. } => true,
        GroupJoinOutcome::Joined { .. } | GroupJoinOutcome::AlreadyMember { .. } => false,
    };
    Ok(json!({"groupId": id, "onlyRequested": only_requested}))
}
