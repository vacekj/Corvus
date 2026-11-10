//! Storage Service: other devices' contact, group and account settings come in through it, and
//! local changes (names, nicknames, notes, blocked, archived, hidden) go out through it.

use std::cell::Cell;

use presage::libsignal_service::prelude::Uuid;
use presage::libsignal_service::storage_service::{ContactPatch, ContactRecordExt, ContactTarget, StorageState};

use crate::ctx::{Account, Ctx, normalize_group_id};
use crate::envelope::group_id_from_master_key;
use crate::rpc::{Method, RpcError, fail, notification};

pub const METHODS: &[Method] = &[];

/// Local value: ids of the groups archived on the phone (from the Storage Service).
pub const ARCHIVED_GROUPS: &str = "archived-groups";

thread_local! {
    static SYNCING: Cell<bool> = const { Cell::new(false) };
}

/// Fetches what changed in the Storage Service and applies it to the local state. One at a time;
/// a call while a sync runs is dropped (the running one fetches the latest manifest anyway).
pub async fn sync(ctx: &Ctx) {
    let Ok(a) = ctx.account() else { return };
    if SYNCING.with(|s| s.replace(true)) {
        return;
    }
    match a.manager().sync_storage_service().await {
        Ok(state) => apply(ctx, a, &state).await,
        Err(error) => tracing::info!(%error, "storage service sync failed"),
    }
    SYNCING.with(|s| s.set(false));
}

/// presage already fetched the latest manifest (it does on a fetch-latest sync message): apply
/// the stored snapshot without going to the network again.
pub async fn apply_stored(ctx: &Ctx) {
    let Ok(a) = ctx.account() else { return };
    match a.manager().storage_state().await {
        Ok(Some(state)) => apply(ctx, a, &state).await,
        Ok(None) => {}
        Err(error) => tracing::info!(%error, "cannot read the storage service snapshot"),
    }
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
    for record in state.groups_v2() {
        let Some(id) = group_id_from_master_key(&record.master_key) else { continue };
        if record.archived {
            archived_groups.push(normalize_group_id(&id));
        }
        if local.group_blocked(&id).await != record.blocked {
            let _ = local.set_group_blocked(&normalize_group_id(&id), record.blocked).await;
        }
    }
    if let Err(error) = local.set_value(ARCHIVED_GROUPS, &archived_groups).await {
        tracing::warn!(%error, "cannot store the archived groups");
    }
    if let Some(account) = state.account() {
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
