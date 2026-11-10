//! send, sendReaction, remoteDelete, sendTyping, sendReceipt, pins, polls, getAttachment.

use std::path::Path;
use std::rc::Rc;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as B64;
use presage::libsignal_service::content::ContentBody;
use presage::proto::{
    AttachmentPointer, BodyRange, DataMessage, EditMessage, Preview, ReceiptMessage, TypingMessage,
    body_range, data_message, receipt_message, typing_message,
};
use presage::store::ContentsStore;
use serde_json::{Value, json};

use super::common::*;
use crate::ctx::{Account, Ctx, now_millis};
use crate::media::attachment_from_file;
use crate::method;
use crate::rpc::{Method, RpcError, fail};

pub const METHODS: &[Method] = &[
    method!("send", send),
    method!("sendReaction", send_reaction),
    method!("remoteDelete", remote_delete),
    method!("sendTyping", send_typing),
    method!("sendReceipt", send_receipt),
    method!("sendPinMessage", send_pin),
    method!("sendUnpinMessage", send_unpin),
    method!("sendPollCreate", poll_create),
    method!("sendPollVote", poll_vote),
    method!("sendPollTerminate", poll_terminate),
    method!("sendStory", send_story),
    method!("getAttachment", get_attachment),
];

/// Protocol version that carries polls (as Signal's clients set it).
const POLL_PROTOCOL_VERSION: u32 = 8;

async fn send(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    let a = ctx.account()?;
    let target = Target::from_params(a, &p).await?;
    let timestamp = now_millis();
    let mut dm = DataMessage {
        timestamp: Some(timestamp),
        group_v2: target.group_context(),
        ..Default::default()
    };
    if let Some(text) = str_param(&p, "message").filter(|s| !s.is_empty()) {
        dm.body = Some(text);
    }
    dm.body_ranges = body_ranges(a, &p).await?;

    let voice_note = bool_param(&p, "voiceNote");
    let files = strs_param(&p, "attachments");
    dm.attachments = upload_files(a, &files, voice_note).await?;
    dm.is_view_once = bool_param(&p, "viewOnce").then_some(true);

    if let Some(sticker) = str_param(&p, "sticker") {
        dm.sticker = Some(sticker_message(&ctx, a, &sticker).await?);
    }
    if let Some(quote_ts) = i64_param(&p, "quoteTimestamp").filter(|t| *t > 0) {
        let author = req_str(&p, "quoteAuthor")?;
        let author = a.resolve_aci(&author).await?;
        dm.quote = Some(data_message::Quote {
            id: Some(quote_ts as u64),
            author_aci: Some(author.to_string()),
            text: str_param(&p, "quoteMessage"),
            r#type: Some(data_message::quote::Type::Normal as i32),
            ..Default::default()
        });
    }
    if let Some(url) = str_param(&p, "previewUrl").filter(|s| !s.is_empty()) {
        let image = match str_param(&p, "previewImage").filter(|s| !s.is_empty()) {
            Some(path) => upload_files(a, &[path], false).await?.into_iter().next(),
            None => None,
        };
        dm.preview = vec![Preview {
            url: Some(url),
            title: str_param(&p, "previewTitle"),
            description: str_param(&p, "previewDescription"),
            image,
            date: None,
        }];
    }
    if let (Some(story_ts), Some(author)) = (
        i64_param(&p, "storyTimestamp").filter(|t| *t > 0),
        str_param(&p, "storyAuthor"),
    ) {
        let author = a.resolve_aci(&author).await?;
        dm.story_context = Some(data_message::StoryContext {
            author_aci: Some(author.to_string()),
            sent_timestamp: Some(story_ts as u64),
            ..Default::default()
        });
    }
    if dm.body.is_none() && dm.attachments.is_empty() && dm.sticker.is_none() {
        return Err(RpcError::invalid_params("Nothing to send: no message, attachment or sticker"));
    }

    let body = match i64_param(&p, "editTimestamp").filter(|t| *t > 0) {
        Some(target_ts) => ContentBody::EditMessage(EditMessage {
            target_sent_timestamp: Some(target_ts as u64),
            data_message: Some(dm),
        }),
        None => ContentBody::DataMessage(dm),
    };
    deliver(a, &target, body, timestamp, false).await
}

/// `textStyle` ("start:length:STYLE") and `mention` ("start:length:uuid-or-number").
async fn body_ranges(a: &Account, p: &Value) -> Result<Vec<BodyRange>, RpcError> {
    let mut out = Vec::new();
    for s in strs_param(p, "textStyle") {
        let Some((start, length, rest)) = split_range(&s) else { continue };
        let style = match rest.to_ascii_uppercase().as_str() {
            "BOLD" => body_range::Style::Bold,
            "ITALIC" => body_range::Style::Italic,
            "SPOILER" => body_range::Style::Spoiler,
            "STRIKETHROUGH" => body_range::Style::Strikethrough,
            "MONOSPACE" => body_range::Style::Monospace,
            _ => continue,
        };
        out.push(BodyRange {
            start: Some(start),
            length: Some(length),
            associated_value: Some(body_range::AssociatedValue::Style(style as i32)),
        });
    }
    for s in strs_param(p, "mention") {
        let Some((start, length, who)) = split_range(&s) else { continue };
        let aci = a.resolve_aci(who).await?;
        out.push(BodyRange {
            start: Some(start),
            length: Some(length),
            associated_value: Some(body_range::AssociatedValue::MentionAci(aci.to_string())),
        });
    }
    Ok(out)
}

fn split_range(s: &str) -> Option<(u32, u32, &str)> {
    let mut it = s.splitn(3, ':');
    let start = it.next()?.trim().parse().ok()?;
    let length = it.next()?.trim().parse().ok()?;
    Some((start, length, it.next()?.trim()))
}

async fn upload_files(a: &Account, paths: &[String], voice_note: bool) -> Result<Vec<AttachmentPointer>, RpcError> {
    if paths.is_empty() {
        return Ok(Vec::new());
    }
    let mut specs = Vec::with_capacity(paths.len());
    for path in paths {
        let path = path.strip_prefix("file://").unwrap_or(path);
        let spec = attachment_from_file(Path::new(path), voice_note)
            .map_err(|e| RpcError::failed(format!("Cannot read attachment {path}: {e}")))?;
        specs.push(spec);
    }
    let mut out = Vec::with_capacity(specs.len());
    for r in a.manager().upload_attachments(specs).await.map_err(fail)? {
        out.push(r.map_err(|e| RpcError::failed(format!("Attachment upload failed: {e}")))?);
    }
    Ok(out)
}

/// `packIdHex:stickerId` -> a sticker message with the sticker image uploaded as its data.
async fn sticker_message(ctx: &Ctx, a: &Account, spec: &str) -> Result<data_message::Sticker, RpcError> {
    let (pack_hex, id) = spec
        .split_once(':')
        .ok_or_else(|| RpcError::invalid_params("sticker must be packId:stickerId"))?;
    let sticker_id: u32 = id.parse().map_err(|_| RpcError::invalid_params("bad sticker id"))?;
    let pack_id = hex::decode(pack_hex).map_err(|_| RpcError::invalid_params("bad sticker pack id"))?;
    let pack = a
        .store
        .sticker_pack(&pack_id)
        .await
        .map_err(fail)?
        .ok_or_else(|| RpcError::failed("Sticker pack is not installed"))?;
    let emoji = pack
        .manifest
        .stickers
        .iter()
        .find(|s| s.id == sticker_id)
        .and_then(|s| s.emoji.clone());
    let bytes = match ctx.dir.sticker(pack_hex, sticker_id).and_then(|p| std::fs::read(p).ok()) {
        Some(b) => b,
        None => a
            .manager()
            .fetch_sticker(&pack_id, &pack.key, sticker_id)
            .await
            .map_err(fail)?,
    };
    let content_type = crate::media::content_type(Path::new("sticker.webp"), &bytes);
    let (width, height) = crate::media::image_size(&bytes).unzip();
    let spec = presage::libsignal_service::sender::AttachmentSpec {
        content_type,
        length: bytes.len(),
        file_name: None,
        preview: None,
        voice_note: None,
        borderless: None,
        width,
        height,
        caption: None,
        blur_hash: None,
    };
    let data = a
        .manager()
        .upload_attachment(spec, bytes)
        .await
        .map_err(fail)?
        .map_err(|e| RpcError::failed(format!("Sticker upload failed: {e}")))?;
    Ok(data_message::Sticker {
        pack_id: Some(pack_id),
        pack_key: Some(pack.key.clone()),
        sticker_id: Some(sticker_id),
        data: Some(data),
        emoji,
    })
}

async fn send_reaction(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    let a = ctx.account()?;
    let target = Target::from_params(a, &p).await?;
    let author = a.resolve_aci(&req_str(&p, "targetAuthor")?).await?;
    let target_ts = req_u64(&p, "targetTimestamp")?;
    let timestamp = now_millis();
    let mut dm = DataMessage {
        timestamp: Some(timestamp),
        group_v2: target.group_context(),
        reaction: Some(data_message::Reaction {
            emoji: Some(req_str(&p, "emoji")?),
            remove: Some(bool_param(&p, "remove")),
            target_author_aci: Some(author.to_string()),
            target_sent_timestamp: Some(target_ts),
            ..Default::default()
        }),
        ..Default::default()
    };
    if bool_param(&p, "story") {
        dm.story_context = Some(data_message::StoryContext {
            author_aci: Some(author.to_string()),
            sent_timestamp: Some(target_ts),
            ..Default::default()
        });
    }
    deliver(a, &target, ContentBody::DataMessage(dm), timestamp, false).await
}

async fn remote_delete(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    let a = ctx.account()?;
    // Corvus uses the plural keys here (signal-cli accepts both).
    let target = if p.get("recipients").is_some() || p.get("groupIds").is_some() {
        Target::from_keys(a, &p, "recipients", "groupIds").await?
    } else {
        Target::from_params(a, &p).await?
    };
    let timestamp = now_millis();
    let dm = DataMessage {
        timestamp: Some(timestamp),
        group_v2: target.group_context(),
        delete: Some(data_message::Delete {
            target_sent_timestamp: Some(req_u64(&p, "targetTimestamp")?),
        }),
        ..Default::default()
    };
    deliver(a, &target, ContentBody::DataMessage(dm), timestamp, false).await
}

async fn send_typing(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    let a = ctx.account()?;
    let target = Target::from_params(a, &p).await?;
    let timestamp = now_millis();
    // Note to Self: nobody to show it to (Signal apps send nothing either).
    if let Target::Contacts(ids) = &target
        && ids.iter().all(|id| *id == a.own_service_id())
    {
        return Ok(json!({"timestamp": timestamp, "results": []}));
    }
    let action = if bool_param(&p, "stop") {
        typing_message::Action::Stopped
    } else {
        typing_message::Action::Started
    };
    let tm = TypingMessage {
        timestamp: Some(timestamp),
        action: Some(action as i32),
        group_id: target.group_id_bytes(),
    };
    deliver(a, &target, ContentBody::TypingMessage(tm), timestamp, true).await
}

async fn send_receipt(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    let a = ctx.account()?;
    let recipient = a.resolve(&req_str(&p, "recipient")?).await?;
    let timestamps: Vec<u64> = i64s_param(&p, "targetTimestamp")
        .into_iter()
        .filter(|t| *t > 0)
        .map(|t| t as u64)
        .collect();
    if timestamps.is_empty() {
        return Err(RpcError::invalid_params("missing parameter targetTimestamp"));
    }
    let kind = match str_param(&p, "type").as_deref() {
        Some("viewed") => receipt_message::Type::Viewed,
        _ => receipt_message::Type::Read,
    };
    let rm = ReceiptMessage {
        r#type: Some(kind as i32),
        timestamp: timestamps,
    };
    let timestamp = now_millis();
    deliver(a, &Target::Contacts(vec![recipient]), ContentBody::ReceiptMessage(rm), timestamp, false).await
}

async fn send_pin(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    let a = ctx.account()?;
    let target = Target::from_params(a, &p).await?;
    let author = a.resolve_aci(&req_str(&p, "targetAuthor")?).await?;
    let duration = match i64_param(&p, "pinDuration") {
        Some(s) if s > 0 => data_message::pin_message::PinDuration::PinDurationSeconds(s as u32),
        _ => data_message::pin_message::PinDuration::PinDurationForever(true),
    };
    let timestamp = now_millis();
    let dm = DataMessage {
        timestamp: Some(timestamp),
        group_v2: target.group_context(),
        pin_message: Some(data_message::PinMessage {
            target_author_aci_binary: Some(author.as_bytes().to_vec()),
            target_sent_timestamp: Some(req_u64(&p, "targetTimestamp")?),
            pin_duration: Some(duration),
        }),
        ..Default::default()
    };
    deliver(a, &target, ContentBody::DataMessage(dm), timestamp, false).await
}

async fn send_unpin(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    let a = ctx.account()?;
    let target = Target::from_params(a, &p).await?;
    let author = a.resolve_aci(&req_str(&p, "targetAuthor")?).await?;
    let timestamp = now_millis();
    let dm = DataMessage {
        timestamp: Some(timestamp),
        group_v2: target.group_context(),
        unpin_message: Some(data_message::UnpinMessage {
            target_author_aci_binary: Some(author.as_bytes().to_vec()),
            target_sent_timestamp: Some(req_u64(&p, "targetTimestamp")?),
        }),
        ..Default::default()
    };
    deliver(a, &target, ContentBody::DataMessage(dm), timestamp, false).await
}

async fn poll_create(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    let a = ctx.account()?;
    let target = Target::from_params(a, &p).await?;
    let options = strs_param(&p, "options");
    if !(2..=10).contains(&options.len()) {
        return Err(RpcError::invalid_params("A poll needs 2 to 10 options"));
    }
    let timestamp = now_millis();
    let dm = DataMessage {
        timestamp: Some(timestamp),
        group_v2: target.group_context(),
        required_protocol_version: Some(POLL_PROTOCOL_VERSION),
        poll_create: Some(data_message::PollCreate {
            question: Some(req_str(&p, "question")?),
            allow_multiple: Some(!bool_param(&p, "noMulti")),
            options,
        }),
        ..Default::default()
    };
    deliver(a, &target, ContentBody::DataMessage(dm), timestamp, false).await
}

async fn poll_vote(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    let a = ctx.account()?;
    let target = Target::from_params(a, &p).await?;
    let author = a.resolve_aci(&req_str(&p, "pollAuthor")?).await?;
    let timestamp = now_millis();
    let dm = DataMessage {
        timestamp: Some(timestamp),
        group_v2: target.group_context(),
        required_protocol_version: Some(POLL_PROTOCOL_VERSION),
        poll_vote: Some(data_message::PollVote {
            target_author_aci_binary: Some(author.as_bytes().to_vec()),
            target_sent_timestamp: Some(req_u64(&p, "pollTimestamp")?),
            option_indexes: i64s_param(&p, "options").into_iter().map(|i| i as u32).collect(),
            vote_count: Some(i64_param(&p, "voteCount").unwrap_or(1).max(1) as u32),
        }),
        ..Default::default()
    };
    deliver(a, &target, ContentBody::DataMessage(dm), timestamp, false).await
}

async fn poll_terminate(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    let a = ctx.account()?;
    let target = Target::from_params(a, &p).await?;
    let timestamp = now_millis();
    let dm = DataMessage {
        timestamp: Some(timestamp),
        group_v2: target.group_context(),
        required_protocol_version: Some(POLL_PROTOCOL_VERSION),
        poll_terminate: Some(data_message::PollTerminate {
            target_sent_timestamp: Some(req_u64(&p, "pollTimestamp")?),
        }),
        ..Default::default()
    };
    deliver(a, &target, ContentBody::DataMessage(dm), timestamp, false).await
}

async fn send_story(_ctx: Rc<Ctx>, _p: Value) -> Result<Value, RpcError> {
    Err(RpcError::not_supported("Posting stories"))
}

/// Received attachments are downloaded on receipt, so this only reads the local file.
async fn get_attachment(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    let id = req_str(&p, "id")?;
    let path = ctx
        .dir
        .attachment(&id)
        .ok_or_else(|| RpcError::invalid_params(format!("Invalid attachment id: {id}")))?;
    let bytes = tokio::fs::read(&path)
        .await
        .map_err(|_| RpcError::failed(format!("Attachment {id} is not available")))?;
    Ok(json!({"data": B64.encode(bytes)}))
}
