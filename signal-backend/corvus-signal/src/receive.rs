//! The receive loop: a long-running websocket that reconnects with backoff, turns every decrypted
//! message into a `receive` notification (after downloading its attachments) and acknowledges it
//! to the server only once the notification is on stdout.

use std::rc::Rc;
use std::time::{Duration, Instant};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as B64;
use futures::StreamExt;
use presage::libsignal_service::content::{Content, ContentBody};
use presage::libsignal_service::messagepipe::AckHandle;
use presage::libsignal_service::prelude::Uuid;
use presage::libsignal_service::protocol::ServiceId;
use presage::model::messages::Received;
use presage::proto::{
    DataMessage, ReceiptMessage, SyncMessage, receipt_message,
    sync_message::{self, Content as SyncContent},
};
use serde_json::json;

use crate::ctx::{Account, Ctx, now_millis};
use crate::envelope::{self, attachment_id, envelope_json};
use crate::files::write_atomic;
use crate::rpc::notification;

const MAX_BACKOFF: Duration = Duration::from_secs(60);
/// A connection that stayed up this long resets the backoff.
const HEALTHY: Duration = Duration::from_secs(60);

/// Runs forever (until the process exits).
pub async fn run(ctx: Rc<Ctx>) {
    let Ok(account) = ctx.account() else { return };
    let mut backoff = Duration::from_secs(1);
    let mut startup_done = false;
    loop {
        let started = Instant::now();
        let mut manager = account.manager();
        match manager.receive_messages().await {
            Ok(stream) => {
                tracing::info!("receiving");
                let mut stream = std::pin::pin!(stream);
                while let Some(item) = stream.next().await {
                    match item {
                        Received::Content(content, ack) => handle(&ctx, account, *content, ack).await,
                        Received::QueueEmpty => {
                            tracing::info!("queue empty");
                            backoff = Duration::from_secs(1);
                            if !startup_done {
                                startup_done = true;
                                let ctx = ctx.clone();
                                tokio::task::spawn_local(async move {
                                    crate::methods::storage::sync(&ctx).await;
                                    if let Ok(account) = ctx.account() {
                                        crate::avatars::sync_missing(account, &ctx.dir).await;
                                    }
                                });
                            }
                        }
                        Received::DecryptionError(_) => {
                            tracing::warn!("a message could not be decrypted");
                        }
                        Received::Contacts => {}
                    }
                }
                tracing::info!(secs = started.elapsed().as_secs(), "receive stream ended");
            }
            Err(error) => {
                if is_unauthorized(&error) {
                    tracing::error!(%error, "authorization failed: this device is no longer linked");
                    crate::shutdown_with_error(
                        account,
                        "This device is no longer linked to the account (authorization failed)",
                    )
                    .await;
                }
                tracing::warn!(%error, "could not start receiving");
            }
        }
        if started.elapsed() >= HEALTHY {
            backoff = Duration::from_secs(1);
        }
        tracing::info!(secs = backoff.as_secs(), "reconnecting");
        tokio::time::sleep(backoff).await;
        backoff = (backoff * 2).min(MAX_BACKOFF);
    }
}

fn is_unauthorized<E: std::error::Error>(error: &presage::Error<E>) -> bool {
    use presage::libsignal_service::prelude::ServiceError;
    matches!(error, presage::Error::ServiceError(ServiceError::Unauthorized))
}

/// Handles one message: side effects, attachment downloads, the notification, the ack, and the
/// delivery receipt.
pub async fn handle(ctx: &Rc<Ctx>, account: &Account, content: Content, ack: AckHandle) {
    apply_side_effects(ctx, account, &content).await;
    download_attachments(ctx, account, &content).await;

    let directory = account.directory().await;
    let source_name = match &content.metadata.sender {
        ServiceId::Aci(aci) => {
            let uuid: Uuid = (*aci).into();
            match account.profile_name(&uuid).await {
                Some(name) => Some(name),
                None => account.contact(&uuid).await.map(|c| c.name).filter(|n| !n.is_empty()),
            }
        }
        ServiceId::Pni(_) => None,
    };
    let envelope = envelope_json(&content, &*directory, source_name.as_deref(), now_millis());
    if let Some(envelope) = envelope {
        let line = notification("receive", json!({"envelope": envelope, "account": account.number}));
        if !ctx.out.send_and_wait(line).await {
            // stdout is gone; let the server deliver it again next time
            ack.nack();
            return;
        }
    }
    drop(ack);

    crate::methods::calls::on_incoming(ctx, &content).await;

    if content.metadata.needs_receipt
        && content.metadata.sender != account.own_service_id()
        && matches!(content.body, ContentBody::DataMessage(_) | ContentBody::EditMessage(_))
    {
        let timestamp = match &content.body {
            ContentBody::DataMessage(DataMessage { timestamp: Some(ts), .. }) => *ts,
            ContentBody::EditMessage(em) => em
                .data_message
                .as_ref()
                .and_then(|d| d.timestamp)
                .unwrap_or_else(|| content.metadata.client_timestamp.timestamp_millis() as u64),
            _ => content.metadata.client_timestamp.timestamp_millis() as u64,
        };
        let sender = content.metadata.sender;
        let mut manager = account.manager();
        tokio::task::spawn_local(async move {
            let receipt = ReceiptMessage {
                r#type: Some(receipt_message::Type::Delivery as i32),
                timestamp: vec![timestamp],
            };
            if let Err(error) = manager.send_message_ext(sender, receipt, now_millis(), false).await {
                tracing::info!(%error, "delivery receipt not sent");
            }
        });
    }
}

async fn apply_side_effects(ctx: &Rc<Ctx>, account: &Account, content: &Content) {
    match &content.body {
        ContentBody::SynchronizeMessage(SyncMessage { content: Some(sync), .. }) => match sync {
            SyncContent::Contacts(_) => {
                // presage stored the contacts before handing the message on
                account.invalidate_directory();
                crate::avatars::write_contact_avatars(account, &ctx.dir).await;
                crate::methods::storage::roster_changed(ctx);
            }
            SyncContent::Blocked(blocked) => apply_blocked(account, blocked).await,
            // Another device changed the Storage Service, or we just got the key to read it.
            SyncContent::FetchLatest(sync_message::FetchLatest { r#type: Some(t) })
                if *t == sync_message::fetch_latest::Type::StorageManifest as i32 =>
            {
                crate::methods::storage::apply_stored(ctx).await;
            }
            SyncContent::Keys(_) => spawn_storage_sync(ctx),
            SyncContent::MessageRequestResponse(r) => apply_message_request(account, r).await,
            SyncContent::Sent(sync_message::Sent { message: Some(dm), .. }) => {
                group_changed(ctx, account, dm);
            }
            _ => {}
        },
        ContentBody::DataMessage(dm) => group_changed(ctx, account, dm),
        _ => {}
    }
}

fn spawn_storage_sync(ctx: &Rc<Ctx>) {
    let ctx = ctx.clone();
    tokio::task::spawn_local(async move {
        crate::methods::storage::sync(&ctx).await;
    });
}

/// A group change (new title, picture, members) refreshes cached names and the group picture.
fn group_changed(ctx: &Rc<Ctx>, account: &Account, dm: &DataMessage) {
    let Some(group) = &dm.group_v2 else { return };
    if group.group_change.as_ref().is_none_or(|c| c.is_empty()) {
        return;
    }
    account.invalidate_directory();
    let Some(key) = group.master_key.as_deref().and_then(|k| <[u8; 32]>::try_from(k).ok()) else {
        return;
    };
    let revision = group.revision.unwrap_or_default();
    let ctx = ctx.clone();
    tokio::task::spawn_local(async move {
        let Ok(account) = ctx.account() else { return };
        // presage already fetched the new group state for this revision
        if let Err(error) = crate::avatars::group_avatar(account, &ctx.dir, &key, revision).await {
            tracing::info!(%error, "group avatar not refreshed");
        }
    });
}

/// The blocked list from another device is the full list: replace ours.
async fn apply_blocked(account: &Account, blocked: &sync_message::Blocked) {
    let local = account.local();
    let mut uuids: Vec<Uuid> = blocked
        .acis_binary
        .iter()
        .filter_map(|b| Uuid::from_slice(b).ok())
        .chain(blocked.acis.iter().filter_map(|s| Uuid::parse_str(s).ok()))
        .collect();
    let mut unknown_numbers = Vec::new();
    for number in &blocked.numbers {
        match account.resolve(number).await {
            Ok(ServiceId::Aci(aci)) => uuids.push(aci.into()),
            _ => unknown_numbers.push(number.clone()),
        }
    }
    for (uuid, c) in local.all_contacts().await {
        if c.blocked && !uuids.contains(&uuid) {
            let _ = local.update_contact(&uuid, |c| c.blocked = false).await;
        }
    }
    for uuid in &uuids {
        let _ = local.update_contact(uuid, |c| c.blocked = true).await;
    }
    let _ = local.set_blocked_numbers(&unknown_numbers).await;
    let groups: Vec<String> = blocked.group_ids.iter().map(|g| B64.encode(g)).collect();
    for g in local.blocked_groups().await {
        if !groups.contains(&g) {
            let _ = local.set_group_blocked(&g, false).await;
        }
    }
    for g in &groups {
        let _ = local.set_group_blocked(g, true).await;
    }
    tracing::info!(people = uuids.len(), groups = groups.len(), "blocked list synced");
}

async fn apply_message_request(account: &Account, r: &sync_message::MessageRequestResponse) {
    use sync_message::message_request_response::Type;
    let t = Type::try_from(r.r#type.unwrap_or_default()).unwrap_or(Type::Unknown);
    let uuid = r
        .thread_aci_binary
        .as_deref()
        .and_then(|b| Uuid::from_slice(b).ok())
        .or_else(|| r.thread_aci.as_deref().and_then(|s| Uuid::parse_str(s).ok()));
    let local = account.local();
    if let Some(uuid) = uuid {
        let _ = local
            .update_contact(&uuid, |c| match t {
                Type::Accept => {
                    c.hidden = false;
                    c.blocked = false;
                }
                Type::Block | Type::BlockAndDelete | Type::BlockAndSpam => c.blocked = true,
                _ => {}
            })
            .await;
    } else if let Some(group_id) = &r.group_id {
        let id = B64.encode(group_id);
        match t {
            Type::Accept => {
                let _ = local.set_group_blocked(&id, false).await;
            }
            Type::Block | Type::BlockAndDelete | Type::BlockAndSpam => {
                let _ = local.set_group_blocked(&id, true).await;
            }
            _ => {}
        }
    }
}

/// Downloads and decrypts every attachment of the message into `DIR/attachments/<id>` (and a
/// received sticker into `DIR/stickers/`). Failures are logged; the message is still delivered.
async fn download_attachments(ctx: &Rc<Ctx>, account: &Account, content: &Content) {
    let manager = account.manager();
    for pointer in envelope::downloadable_attachments(&content.body) {
        let id = attachment_id(pointer);
        let Some(path) = ctx.dir.attachment(&id) else { continue };
        if path.exists() || pointer.key.is_none() || pointer.digest.is_none() {
            continue;
        }
        let started = Instant::now();
        match manager.get_attachment(pointer).await {
            Ok(bytes) => {
                if let Err(error) = write_atomic(&path, &bytes) {
                    tracing::warn!(%error, "could not write attachment");
                } else {
                    tracing::info!(
                        bytes = bytes.len(),
                        ms = started.elapsed().as_millis() as u64,
                        "attachment downloaded"
                    );
                }
            }
            Err(error) => tracing::warn!(%error, "attachment download failed"),
        }
    }

    if let Some(sticker) = envelope::sticker_of(&content.body) {
        let pack_id = hex::encode(sticker.pack_id.as_deref().unwrap_or_default());
        let local = account.local();
        if let Some(key) = sticker.pack_key.as_deref().filter(|k| !k.is_empty()) {
            if local.sticker_key(&pack_id).await.is_none() {
                let _ = local.set_sticker_key(&pack_id, key).await;
            }
        }
        let (Some(id), Some(pointer)) = (sticker.sticker_id, sticker.data.as_ref()) else {
            return;
        };
        let Some(path) = ctx.dir.sticker(&pack_id, id) else { return };
        if path.exists() {
            return;
        }
        match manager.get_attachment(pointer).await {
            Ok(bytes) => {
                let _ = write_atomic(&path, &bytes);
            }
            Err(error) => tracing::info!(%error, "sticker download failed"),
        }
    }
}
