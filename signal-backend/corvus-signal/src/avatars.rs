//! Profile, contact and group pictures, written to `DIR/avatars/` under the names signal-cli used
//! (`profile-<number or uuid>`, `contact-<number or uuid>`, `group-<base64url id>`). Corvus reads
//! these files directly when the directory exists, else it calls `getAvatar`.

use presage::libsignal_service::prelude::Uuid;
use presage::libsignal_service::protocol::{Aci, ServiceId};
use presage::proto::GroupContextV2;
use presage::store::ContentsStore;

use crate::ctx::{Account, now_millis};
use crate::envelope::group_id_from_master_key;
use crate::files::{DataDir, write_atomic};
use crate::rpc::{RpcError, fail};

/// Writes `profile-<key>` for an account and returns the picture. With `network` false only
/// cached data is used. `Ok(None)`: the profile has no picture (any stale file is removed).
pub async fn profile_avatar(
    account: &Account,
    dir: &DataDir,
    uuid: &Uuid,
    network: bool,
) -> Result<Option<Vec<u8>>, RpcError> {
    let key = account.key_for(uuid).await;
    let path = dir
        .profile_avatar(&key)
        .ok_or_else(|| RpcError::invalid_params("invalid id"))?;
    let profile_key = if *uuid == account.aci {
        Some(account.profile_key())
    } else {
        let id: ServiceId = Aci::from(*uuid).into();
        account.store.profile_key(&id).await.map_err(fail)?
    };
    let Some(profile_key) = profile_key else {
        return Ok(None);
    };
    if !network {
        let cached = account
            .store
            .profile_avatar(*uuid, profile_key)
            .await
            .ok()
            .flatten();
        if let Some(bytes) = &cached {
            write_atomic(&path, bytes).map_err(fail)?;
        }
        return Ok(cached);
    }
    let mut manager = account.manager();
    match manager
        .retrieve_profile_avatar_by_uuid(*uuid, profile_key)
        .await
        .map_err(fail)?
    {
        Some(bytes) => {
            write_atomic(&path, &bytes).map_err(fail)?;
            Ok(Some(bytes))
        }
        None => {
            let _ = std::fs::remove_file(&path);
            Ok(None)
        }
    }
}

/// Writes `contact-<key>` from the picture the primary device sent with the contacts sync.
pub async fn contact_avatar(account: &Account, dir: &DataDir, uuid: &Uuid) -> Option<Vec<u8>> {
    let contact = account.contact(uuid).await?;
    let bytes = contact.avatar.map(|a| a.reader.to_vec()).filter(|b| !b.is_empty())?;
    let path = dir.contact_avatar(&account.key_for(uuid).await)?;
    write_atomic(&path, &bytes).ok()?;
    Some(bytes)
}

/// Writes `group-<id>` for a group (fetching it if needed).
pub async fn group_avatar(
    account: &Account,
    dir: &DataDir,
    master_key: &[u8; 32],
    revision: u32,
) -> Result<Option<Vec<u8>>, RpcError> {
    let group_id = group_id_from_master_key(master_key).ok_or_else(|| RpcError::failed("bad group"))?;
    let path = dir
        .group_avatar(&group_id)
        .ok_or_else(|| RpcError::invalid_params("invalid group id"))?;
    let mut manager = account.manager();
    let avatar = manager
        .retrieve_group_avatar(GroupContextV2 {
            master_key: Some(master_key.to_vec()),
            revision: Some(revision),
            group_change: None,
        })
        .await
        .map_err(fail)?;
    match &avatar {
        Some(bytes) if !bytes.is_empty() => write_atomic(&path, bytes).map_err(fail)?,
        _ => {
            let _ = std::fs::remove_file(&path);
        }
    }
    Ok(avatar.filter(|b| !b.is_empty()))
}

/// Writes all contact pictures from the last contacts sync.
pub async fn write_contact_avatars(account: &Account, dir: &DataDir) {
    for contact in account.contacts().await.unwrap_or_default() {
        if contact.avatar.as_ref().is_some_and(|a| !a.reader.is_empty()) {
            contact_avatar(account, dir, &contact.uuid).await;
        }
    }
}

/// Fills in missing picture files after start-up: own profile, groups, contacts' profiles.
/// Only files that do not exist yet are fetched, slowly, one at a time.
pub async fn sync_missing(account: &Account, dir: &DataDir) {
    let started = now_millis();
    if let Err(error) = profile_avatar(account, dir, &account.aci.clone(), true).await {
        tracing::info!(%error, "own avatar not fetched");
    }
    write_contact_avatars(account, dir).await;

    for (key, group) in account.groups().await.unwrap_or_default() {
        if group.avatar.is_empty() {
            continue;
        }
        let Some(path) = group_id_from_master_key(&key).and_then(|id| dir.group_avatar(&id)) else {
            continue;
        };
        if path.exists() {
            continue;
        }
        if let Err(error) = group_avatar(account, dir, &key, group.revision).await {
            tracing::info!(%error, "group avatar not fetched");
        }
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    }

    let mut fetched = 0;
    for contact in account.contacts().await.unwrap_or_default() {
        if contact.profile_key.len() != 32 {
            continue;
        }
        let key = account.key_for(&contact.uuid).await;
        if dir.profile_avatar(&key).is_none_or(|p| p.exists()) {
            continue;
        }
        match profile_avatar(account, dir, &contact.uuid, true).await {
            Ok(_) => fetched += 1,
            Err(error) => tracing::info!(%error, "profile avatar not fetched"),
        }
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    }
    tracing::info!(fetched, ms = now_millis() - started, "avatar sync done");
}
