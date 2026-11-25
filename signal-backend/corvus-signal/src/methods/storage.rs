//! Storage Service: other devices' contact, group and account settings come in through it, and
//! local changes (names, nicknames, notes, blocked, archived, hidden) go out through it.

use std::cell::Cell;

use presage::libsignal_service::prelude::Uuid;
use presage::libsignal_service::storage_service::{
    AccountPatch, ContactPatch, ContactRecordExt, ContactTarget, StorageState,
};
use presage::proto::account_record::{self, pinned_conversation::{self, Identifier}};

use crate::ctx::{Account, Ctx, normalize_group_id};
use crate::envelope::group_id_from_master_key;
use crate::rpc::{Method, RpcError, fail, notification};

pub const METHODS: &[Method] = &[];

/// Local value: ids of the groups archived on the phone (from the Storage Service).
pub const ARCHIVED_GROUPS: &str = "archived-groups";
/// Local value: group id → muted-until (ms) of the groups muted on the phone.
pub const MUTED_GROUPS: &str = "muted-groups";
/// Local value: ids of the groups marked unread on the phone.
pub const UNREAD_GROUPS: &str = "unread-groups";
/// Local value: ids of the muted groups whose @mentions should stay quiet too.
pub const QUIET_MENTION_GROUPS: &str = "quiet-mention-groups";
/// Local value: pinned chats in the phone's order, as contact ACIs and `g:<group id>`.
pub const PINNED: &str = "pinned-chats";

/// Signal shows at most this many pinned chats.
pub const MAX_PINNED: usize = 4;

/// Mute end as Corvus reads it: 0 = not muted, -1 = for good, else ms since 1970.
pub fn mute_json(until: u64) -> i64 {
    if until >= (i64::MAX as u64) / 2 { -1 } else { until as i64 }
}

thread_local! {
    static SYNCING: Cell<bool> = const { Cell::new(false) };
    static AGAIN: Cell<bool> = const { Cell::new(false) };
}

/// Fetches what changed in the Storage Service and applies it to the local state. One at a time;
/// a call while a sync runs makes that sync run once more when it is done (its manifest may be older
/// than the change that was announced).
pub async fn sync(ctx: &Ctx) {
    let Ok(a) = ctx.account() else { return };
    if SYNCING.with(|s| s.replace(true)) {
        AGAIN.with(|s| s.set(true));
        return;
    }
    loop {
        AGAIN.with(|s| s.set(false));
        match a.manager().sync_storage_service().await {
            Ok(state) => apply(ctx, a, &state).await,
            Err(error) => tracing::info!(%error, "storage service sync failed"),
        }
        if !AGAIN.with(|s| s.get()) {
            break;
        }
    }
    SYNCING.with(|s| s.set(false));
}

/// Mirrors the Storage Service records into the local contact and group state.
async fn apply(ctx: &Ctx, a: &Account, state: &StorageState) {
    let local = a.local();
    for record in state.contacts() {
        // aciBinary (newer clients write only that) or the aci string
        let Some(uuid) = record.aci_uuid() else { continue };
        let nickname = record.nickname.clone().unwrap_or_default();
        let result = local
            .update_contact(&uuid, |c| {
                c.blocked = record.blocked;
                c.hidden = record.hidden;
                c.archived = record.archived;
                c.muted_until = record.muted_until_timestamp;
                c.marked_unread = record.marked_unread;
                c.nick_given_name = nickname.given.clone();
                c.nick_family_name = nickname.family.clone();
                c.note = record.note.clone();
                c.given_name = record.system_given_name.clone();
                c.family_name = record.system_family_name.clone();
            })
            .await;
        if let Err(error) = result {
            tracing::warn!(%error, "cannot store a contact record");
        }
    }
    let mut archived_groups = Vec::new();
    let mut muted_groups = std::collections::BTreeMap::<String, u64>::new();
    let mut unread_groups = Vec::new();
    let mut quiet_mention_groups = Vec::new();
    for record in state.groups_v2() {
        let Some(id) = group_id_from_master_key(&record.master_key) else { continue };
        if record.archived {
            archived_groups.push(normalize_group_id(&id));
        }
        if record.marked_unread {
            unread_groups.push(normalize_group_id(&id));
        }
        if record.dont_notify_for_mentions_if_muted {
            quiet_mention_groups.push(normalize_group_id(&id));
        }
        if record.muted_until_timestamp > 0 {
            muted_groups.insert(normalize_group_id(&id), record.muted_until_timestamp);
        }
        if local.group_blocked(&id).await != record.blocked {
            let _ = local.set_group_blocked(&normalize_group_id(&id), record.blocked).await;
        }
    }
    if let Err(error) = local.set_value(ARCHIVED_GROUPS, &archived_groups).await {
        tracing::warn!(%error, "cannot store the archived groups");
    }
    if let Err(error) = local.set_value(MUTED_GROUPS, &muted_groups).await {
        tracing::warn!(%error, "cannot store the muted groups");
    }
    let _ = local.set_value(UNREAD_GROUPS, &unread_groups).await;
    let _ = local.set_value(QUIET_MENTION_GROUPS, &quiet_mention_groups).await;
    if let Some(account) = state.account() {
        let mut pinned = Vec::new();
        for pin in &account.pinned_conversations {
            if let Some(key) = pin_key(a, pin).await {
                pinned.push(key);
            }
        }
        let _ = local.set_value(PINNED, &pinned).await;
        let username = (!account.username.is_empty()).then_some(account.username.as_str());
        let _ = local.set_own_username(username).await;
    }
    a.invalidate_directory();
    tracing::info!(
        version = state.version(),
        contacts = state.contacts().count(),
        groups = state.groups_v2().count(),
        archived_contacts = state.contacts().filter(|c| c.archived).count(),
        archived_groups = state.groups_v2().filter(|g| g.archived).count(),
        "storage service applied"
    );
    roster_changed(ctx);
}

/// The local key of a pinned chat: contact ACI string or `g:<group id>`.
async fn pin_key(a: &Account, pin: &account_record::PinnedConversation) -> Option<String> {
    match pin.identifier.as_ref()? {
        Identifier::Contact(c) => pin_contact_uuid(a, c).await.map(|u| u.to_string()),
        Identifier::GroupMasterKey(mk) => {
            group_id_from_master_key(mk).map(|id| format!("g:{}", normalize_group_id(&id)))
        }
        _ => None,
    }
}

async fn pin_contact_uuid(a: &Account, c: &pinned_conversation::Contact) -> Option<Uuid> {
    if let Ok(u) = Uuid::from_slice(&c.service_id_binary) {
        return Some(u);
    }
    if let Ok(u) = Uuid::parse_str(&c.service_id) {
        return Some(u);
    }
    if !c.e164.is_empty() {
        return a.resolve_aci(&c.e164).await.ok();
    }
    None
}

/// Pins or unpins a chat (`key` as in `PINNED`) in the AccountRecord's pinned list, keeping the
/// other pins as they are. Pinning when the list is full fails (Signal shows only four).
pub async fn set_pinned(a: &Account, key: &str, master_key: Option<[u8; 32]>, pinned: bool) -> Result<(), RpcError> {
    let state = a.manager().storage_state().await.map_err(fail)?;
    let mut pins: Vec<account_record::PinnedConversation> =
        state.as_ref().and_then(|s| s.account()).map(|r| r.pinned_conversations.clone()).unwrap_or_default();
    let mut kept = Vec::new();
    for pin in pins.drain(..) {
        if pin_key(a, &pin).await.as_deref() != Some(key) {
            kept.push(pin);
        }
    }
    if pinned {
        if kept.len() >= MAX_PINNED {
            return Err(RpcError::failed(format!("Signal allows only {MAX_PINNED} pinned chats")));
        }
        let identifier = match master_key {
            Some(mk) => Identifier::GroupMasterKey(mk.to_vec()),
            None => {
                let uuid = Uuid::parse_str(key).map_err(|_| RpcError::invalid_params("bad contact"))?;
                Identifier::Contact(pinned_conversation::Contact {
                    service_id: uuid.to_string(),
                    e164: String::new(),
                    service_id_binary: uuid.as_bytes().to_vec(),
                })
            }
        };
        kept.push(account_record::PinnedConversation { identifier: Some(identifier) });
    }
    let mut local_keys = Vec::new();
    for pin in &kept {
        if let Some(k) = pin_key(a, pin).await {
            local_keys.push(k);
        }
    }
    a.local().set_value(PINNED, &local_keys).await.map_err(fail)?;
    a.manager()
        .update_account_record(AccountPatch { pinned_conversations: Some(kept), ..Default::default() })
        .await
        .map_err(fail)?;
    Ok(())
}

/// Tells Corvus to list contacts and groups again (names, archive and block state changed).
pub fn roster_changed(ctx: &Ctx) {
    ctx.out.send(notification("rosterChanged", serde_json::json!({})));
}

/// A contact's names, nickname, note, archived or hidden state changed locally: write it to the
/// Storage Service so the phone and other devices see it. Failures are logged, not reported:
/// the local change already happened.
pub async fn contact_changed(a: &Account, uuid: &Uuid) {
    let c = a.local().contact(uuid).await;
    let patch = ContactPatch {
        system_given_name: Some(c.given_name),
        system_family_name: Some(c.family_name),
        nickname_given_name: Some(c.nick_given_name),
        nickname_family_name: Some(c.nick_family_name),
        note: Some(c.note),
        archived: Some(c.archived),
        marked_unread: Some(c.marked_unread),
        hidden: Some(c.hidden),
        ..Default::default()
    };
    if let Err(error) = a.manager().update_contact_record(ContactTarget::aci(*uuid), patch).await {
        tracing::info!(%error, "contact record write failed");
    }
}

/// Blocks or unblocks a contact everywhere (Storage Service plus the blocked-list sync).
pub async fn set_contact_blocked(a: &Account, uuid: &Uuid, blocked: bool) -> Result<(), RpcError> {
    a.local().update_contact(uuid, |c| c.blocked = blocked).await.map_err(fail)?;
    a.manager().set_contact_blocked(ContactTarget::aci(*uuid), blocked).await.map_err(fail)?;
    Ok(())
}

pub async fn set_group_blocked(a: &Account, group_id: &str, master_key: [u8; 32], blocked: bool) -> Result<(), RpcError> {
    a.local().set_group_blocked(group_id, blocked).await.map_err(fail)?;
    a.manager().set_group_blocked(master_key, blocked).await.map_err(fail)?;
    Ok(())
}

pub async fn set_number_privacy(a: &Account, sharing: Option<bool>, discoverable: Option<bool>) -> Result<(), RpcError> {
    let mut mgr = a.manager();
    if let Some(share) = sharing {
        mgr.set_phone_number_sharing(share).await.map_err(fail)?;
    }
    if let Some(discoverable) = discoverable {
        mgr.set_discoverable_by_phone_number(discoverable).await.map_err(fail)?;
    }
    Ok(())
}
