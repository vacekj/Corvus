//! Decrypted `Content` (protobuf) -> signal-cli envelope JSON, as Corvus parses it
//! (docs/corvus-rpc-spec.md section 4).
//!
//! Pure functions: everything that needs the store comes in through [Lookup].

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as B64;
use presage::libsignal_service::content::{Content, ContentBody};
use presage::libsignal_service::prelude::Uuid;
use presage::libsignal_service::protocol::ServiceId;
use presage::libsignal_service::zkgroup::groups::{GroupMasterKey, GroupSecretParams};
use presage::proto::{
    self, AttachmentPointer, BodyRange, DataMessage, EditMessage, GroupContextV2, ReceiptMessage,
    SyncMessage, TypingMessage, attachment_pointer, body_range, data_message,
    sync_message::{self, Content as SyncContent},
};
use serde_json::{Map, Value, json};

/// What the mapping needs to know beyond the protobuf.
pub trait Lookup {
    /// The E.164 number of an account, if known.
    fn number_of(&self, uuid: &Uuid) -> Option<String>;
    /// The title of a group, by master key.
    fn group_name(&self, master_key: &[u8]) -> Option<String>;
}

/// The base64 group id (the group identifier derived from the master key), as listGroups returns it.
pub fn group_id_from_master_key(master_key: &[u8]) -> Option<String> {
    let bytes: [u8; 32] = master_key.try_into().ok()?;
    let params = GroupSecretParams::derive_from_master_key(GroupMasterKey::new(bytes));
    Some(B64.encode(params.get_group_identifier()))
}

/// The file name / envelope id of an attachment: its CDN key (or id) plus an extension from the
/// content type. Filename-safe (`^[A-Za-z0-9_.-]+$`), stable for the same pointer.
pub fn attachment_id(pointer: &AttachmentPointer) -> String {
    let base = match &pointer.attachment_identifier {
        Some(attachment_pointer::AttachmentIdentifier::CdnKey(key)) if !key.is_empty() => {
            key.clone()
        }
        Some(attachment_pointer::AttachmentIdentifier::CdnId(id)) if *id != 0 => id.to_string(),
        _ => match pointer.digest.as_deref() {
            Some(d) if !d.is_empty() => hex::encode(&d[..d.len().min(16)]),
            _ => format!("att{}", pointer.upload_timestamp.unwrap_or_default()),
        },
    };
    let mut id: String = base
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '_' })
        .collect();
    if let Some(ext) = attachment_extension(pointer) {
        id.push('.');
        id.push_str(&ext);
    }
    id
}

fn attachment_extension(pointer: &AttachmentPointer) -> Option<String> {
    let from_type = pointer
        .content_type
        .as_deref()
        .and_then(extension_for_content_type);
    let from_name = || {
        pointer
            .file_name
            .as_deref()
            .and_then(|n| n.rsplit_once('.'))
            .map(|(_, ext)| ext.to_ascii_lowercase())
            .filter(|ext| (1..=8).contains(&ext.len()) && ext.bytes().all(|b| b.is_ascii_alphanumeric()))
    };
    from_type.or_else(from_name)
}

fn extension_for_content_type(content_type: &str) -> Option<String> {
    let ct = content_type.split(';').next()?.trim().to_ascii_lowercase();
    let preferred = match ct.as_str() {
        "image/jpeg" => Some("jpg"),
        "image/png" => Some("png"),
        "image/gif" => Some("gif"),
        "image/webp" => Some("webp"),
        "image/heic" => Some("heic"),
        "video/mp4" => Some("mp4"),
        "video/quicktime" => Some("mov"),
        "audio/aac" => Some("aac"),
        "audio/mp4" => Some("m4a"),
        "audio/mpeg" => Some("mp3"),
        "audio/ogg" => Some("ogg"),
        "application/pdf" => Some("pdf"),
        "text/plain" => Some("txt"),
        "text/x-signal-plain" => Some("txt"),
        _ => None,
    };
    if let Some(ext) = preferred {
        return Some(ext.to_owned());
    }
    mime_guess::get_mime_extensions_str(&ct)
        .and_then(|exts| exts.first())
        .map(|e| e.to_string())
}

fn uuid_from(string: Option<&str>, binary: Option<&[u8]>) -> Option<Uuid> {
    binary
        .and_then(|b| Uuid::from_slice(b).ok())
        .or_else(|| string.and_then(|s| Uuid::parse_str(s).ok()))
}

/// `(identifier, number, uuid)` for an ACI: identifier is the number when known.
fn address(lookup: &dyn Lookup, uuid: &Uuid) -> (String, Option<String>, String) {
    let number = lookup.number_of(uuid);
    let uuid = uuid.to_string();
    (number.clone().unwrap_or_else(|| uuid.clone()), number, uuid)
}

fn service_address(lookup: &dyn Lookup, id: &ServiceId) -> (String, Option<String>, String) {
    match id {
        ServiceId::Aci(aci) => address(lookup, &Uuid::from(*aci)),
        ServiceId::Pni(_) => {
            let s = id.service_id_string();
            (s.clone(), None, s)
        }
    }
}

fn put(map: &mut Map<String, Value>, key: &str, value: impl Into<Value>) {
    map.insert(key.to_owned(), value.into());
}

fn put_opt<T: Into<Value>>(map: &mut Map<String, Value>, key: &str, value: Option<T>) {
    if let Some(v) = value {
        map.insert(key.to_owned(), v.into());
    }
}

/// Maps a decrypted message to the envelope JSON. `None` for content Corvus has no use for
/// (null messages, call signaling, stories, sync messages without a mapped field).
pub fn envelope_json(
    content: &Content,
    lookup: &dyn Lookup,
    source_name: Option<&str>,
    delivered_timestamp: u64,
) -> Option<Value> {
    let meta = &content.metadata;
    let timestamp = meta.client_timestamp.timestamp_millis().max(0) as u64;
    let (key, value) = match &content.body {
        ContentBody::DataMessage(dm) => ("dataMessage", data_message_json(dm, lookup, timestamp)),
        ContentBody::EditMessage(em) => ("editMessage", edit_message_json(em, lookup)?),
        ContentBody::SynchronizeMessage(sm) => ("syncMessage", sync_message_json(sm, lookup)?),
        ContentBody::ReceiptMessage(rm) => ("receiptMessage", receipt_json(rm, timestamp)),
        ContentBody::TypingMessage(tm) => ("typingMessage", typing_json(tm, timestamp)),
        ContentBody::NullMessage(_)
        | ContentBody::CallMessage(_)
        | ContentBody::StoryMessage(_)
        | ContentBody::DecryptionErrorMessage(_) => return None,
    };

    let (source, number, uuid) = service_address(lookup, &meta.sender);
    let mut env = Map::new();
    put(&mut env, "source", source);
    put(&mut env, "sourceNumber", number);
    put(&mut env, "sourceUuid", uuid);
    put(&mut env, "sourceName", source_name.filter(|s| !s.is_empty()));
    put(&mut env, "sourceDevice", u32::from(meta.sender_device));
    put(&mut env, "timestamp", timestamp);
    put(
        &mut env,
        "serverReceivedTimestamp",
        meta.server_timestamp.timestamp_millis().max(0) as u64,
    );
    put(&mut env, "serverDeliveredTimestamp", delivered_timestamp);
    env.insert(key.to_owned(), value);
    Some(Value::Object(env))
}

pub fn attachment_json(p: &AttachmentPointer) -> Value {
    let mut m = Map::new();
    put(&mut m, "contentType", p.content_type.clone().unwrap_or_else(|| "application/octet-stream".into()));
    put(&mut m, "filename", p.file_name.clone());
    put(&mut m, "id", attachment_id(p));
    put(&mut m, "size", p.size.map(u64::from));
    put_opt(&mut m, "width", p.width.filter(|w| *w > 0));
    put_opt(&mut m, "height", p.height.filter(|h| *h > 0));
    put_opt(&mut m, "caption", p.caption.clone().filter(|c| !c.is_empty()));
    put_opt(&mut m, "uploadTimestamp", p.upload_timestamp);
    let flags = p.flags.unwrap_or_default();
    if flags & attachment_pointer::Flags::VoiceMessage as u32 != 0 {
        put(&mut m, "voiceNote", true);
    }
    if flags & attachment_pointer::Flags::Gif as u32 != 0 {
        put(&mut m, "gif", true);
    }
    Value::Object(m)
}

fn style_name(style: i32) -> &'static str {
    match body_range::Style::try_from(style).unwrap_or(body_range::Style::None) {
        body_range::Style::None => "NONE",
        body_range::Style::Bold => "BOLD",
        body_range::Style::Italic => "ITALIC",
        body_range::Style::Spoiler => "SPOILER",
        body_range::Style::Strikethrough => "STRIKETHROUGH",
        body_range::Style::Monospace => "MONOSPACE",
    }
}

fn mentions_json(ranges: &[BodyRange], lookup: &dyn Lookup) -> Vec<Value> {
    ranges
        .iter()
        .filter_map(|r| {
            let uuid = match &r.associated_value {
                Some(body_range::AssociatedValue::MentionAci(s)) => Uuid::parse_str(s).ok(),
                Some(body_range::AssociatedValue::MentionAciBinary(b)) => Uuid::from_slice(b).ok(),
                _ => None,
            }?;
            let (name, number, uuid) = address(lookup, &uuid);
            Some(json!({
                "name": name,
                "number": number,
                "uuid": uuid,
                "start": r.start.unwrap_or_default(),
                "length": r.length.unwrap_or_default(),
            }))
        })
        .collect()
}

fn text_styles_json(ranges: &[BodyRange]) -> Vec<Value> {
    ranges
        .iter()
        .filter_map(|r| match r.associated_value {
            Some(body_range::AssociatedValue::Style(style)) => Some(json!({
                "style": style_name(style),
                "start": r.start.unwrap_or_default(),
                "length": r.length.unwrap_or_default(),
            })),
            _ => None,
        })
        .collect()
}

fn group_info_json(g: &GroupContextV2, lookup: &dyn Lookup) -> Option<Value> {
    let master_key = g.master_key.as_deref()?;
    let id = group_id_from_master_key(master_key)?;
    let mut m = Map::new();
    put(&mut m, "groupId", id);
    put_opt(&mut m, "groupName", lookup.group_name(master_key));
    put(&mut m, "revision", g.revision.unwrap_or_default());
    let update = g.group_change.as_ref().is_some_and(|c| !c.is_empty());
    put(&mut m, "type", if update { "UPDATE" } else { "DELIVER" });
    Some(Value::Object(m))
}

/// `{author, authorNumber, authorUuid}`-style fields under the given key prefix.
fn author_fields(m: &mut Map<String, Value>, prefix: &str, uuid: Option<Uuid>, lookup: &dyn Lookup) {
    if let Some(uuid) = uuid {
        let (id, number, uuid) = address(lookup, &uuid);
        put(m, prefix, id);
        put(m, &format!("{prefix}Number"), number);
        put(m, &format!("{prefix}Uuid"), uuid);
    }
}

fn quote_json(q: &data_message::Quote, lookup: &dyn Lookup) -> Value {
    let mut m = Map::new();
    put(&mut m, "id", q.id.unwrap_or_default());
    author_fields(
        &mut m,
        "author",
        uuid_from(q.author_aci.as_deref(), q.author_aci_binary.as_deref()),
        lookup,
    );
    put(&mut m, "text", q.text.clone());
    put(&mut m, "mentions", mentions_json(&q.body_ranges, lookup));
    let attachments: Vec<Value> = q
        .attachments
        .iter()
        .map(|a| {
            let mut am = Map::new();
            put(&mut am, "contentType", a.content_type.clone());
            put(&mut am, "filename", a.file_name.clone());
            put(&mut am, "thumbnail", a.thumbnail.as_ref().map(attachment_json));
            Value::Object(am)
        })
        .collect();
    put(&mut m, "attachments", attachments);
    let styles = text_styles_json(&q.body_ranges);
    if !styles.is_empty() {
        put(&mut m, "textStyles", styles);
    }
    Value::Object(m)
}

fn reaction_json(r: &data_message::Reaction, lookup: &dyn Lookup) -> Value {
    let mut m = Map::new();
    put(&mut m, "emoji", r.emoji.clone().unwrap_or_default());
    author_fields(
        &mut m,
        "targetAuthor",
        uuid_from(r.target_author_aci.as_deref(), r.target_author_aci_binary.as_deref()),
        lookup,
    );
    put(&mut m, "targetSentTimestamp", r.target_sent_timestamp.unwrap_or_default());
    put(&mut m, "isRemove", r.remove.unwrap_or(false));
    Value::Object(m)
}

fn contact_type_name(t: Option<i32>, kind: &str) -> Value {
    let name = match (kind, t.unwrap_or(0)) {
        ("address", 1) => "HOME",
        ("address", 2) => "WORK",
        ("address", 3) => "CUSTOM",
        (_, 1) => "HOME",
        (_, 2) => "MOBILE",
        (_, 3) => "WORK",
        (_, 4) => "CUSTOM",
        _ => return Value::Null,
    };
    Value::String(name.to_owned())
}

fn shared_contact_json(c: &data_message::Contact) -> Value {
    let mut m = Map::new();
    let mut name = Map::new();
    if let Some(n) = &c.name {
        put(&mut name, "given", n.given_name.clone());
        put(&mut name, "family", n.family_name.clone());
        put(&mut name, "prefix", n.prefix.clone());
        put(&mut name, "suffix", n.suffix.clone());
        put(&mut name, "middle", n.middle_name.clone());
        put(&mut name, "nickname", n.nickname.clone());
    }
    put(&mut m, "name", Value::Object(name));
    put(
        &mut m,
        "avatar",
        c.avatar.as_ref().and_then(|a| {
            a.avatar.as_ref().map(|p| {
                json!({"attachment": attachment_json(p), "isProfile": a.is_profile.unwrap_or(false)})
            })
        }),
    );
    let phones: Vec<Value> = c
        .number
        .iter()
        .map(|p| json!({"value": p.value, "type": contact_type_name(p.r#type, "phone"), "label": p.label}))
        .collect();
    put(&mut m, "phone", phones);
    let emails: Vec<Value> = c
        .email
        .iter()
        .map(|e| json!({"value": e.value, "type": contact_type_name(e.r#type, "email"), "label": e.label}))
        .collect();
    put(&mut m, "email", emails);
    let addresses: Vec<Value> = c
        .address
        .iter()
        .map(|a| {
            json!({
                "type": contact_type_name(a.r#type, "address"),
                "label": a.label,
                "street": a.street,
                "pobox": a.pobox,
                "neighborhood": a.neighborhood,
                "city": a.city,
                "region": a.region,
                "postcode": a.postcode,
                "country": a.country,
            })
        })
        .collect();
    put(&mut m, "address", addresses);
    put(&mut m, "organization", c.organization.clone());
    Value::Object(m)
}

fn payment_json(p: &data_message::Payment) -> Option<Value> {
    match &p.item {
        Some(data_message::payment::Item::Notification(n)) => {
            let receipt = match &n.transaction {
                Some(data_message::payment::notification::Transaction::MobileCoin(mc)) => {
                    mc.receipt.as_ref().map(|r| B64.encode(r))
                }
                None => None,
            };
            Some(json!({"note": n.note.clone().unwrap_or_default(), "receipt": receipt}))
        }
        _ => None,
    }
}

/// The JSON of a `DataMessage` (signal-cli's `JsonDataMessage`).
pub fn data_message_json(dm: &DataMessage, lookup: &dyn Lookup, fallback_timestamp: u64) -> Value {
    Value::Object(data_message_map(dm, lookup, fallback_timestamp))
}

fn data_message_map(dm: &DataMessage, lookup: &dyn Lookup, fallback_timestamp: u64) -> Map<String, Value> {
    let mut m = Map::new();
    put(&mut m, "timestamp", dm.timestamp.unwrap_or(fallback_timestamp));
    put(&mut m, "message", dm.body.clone());
    put(&mut m, "expiresInSeconds", dm.expire_timer.unwrap_or_default());
    put(&mut m, "viewOnce", dm.is_view_once.unwrap_or(false));
    let flags = dm.flags.unwrap_or_default();
    if flags & data_message::Flags::ExpirationTimerUpdate as u32 != 0 {
        put(&mut m, "isExpirationUpdate", true);
    }
    if flags & data_message::Flags::ProfileKeyUpdate as u32 != 0 {
        put(&mut m, "isProfileKeyUpdate", true);
    }
    if let Some(info) = dm.group_v2.as_ref().and_then(|g| group_info_json(g, lookup)) {
        put(&mut m, "groupInfo", info);
    }
    if !dm.attachments.is_empty() {
        put(&mut m, "attachments", dm.attachments.iter().map(attachment_json).collect::<Vec<_>>());
    }
    let mentions = mentions_json(&dm.body_ranges, lookup);
    if !mentions.is_empty() {
        put(&mut m, "mentions", mentions);
    }
    let styles = text_styles_json(&dm.body_ranges);
    if !styles.is_empty() {
        put(&mut m, "textStyles", styles);
    }
    if let Some(q) = &dm.quote {
        put(&mut m, "quote", quote_json(q, lookup));
    }
    if let Some(r) = &dm.reaction {
        put(&mut m, "reaction", reaction_json(r, lookup));
    }
    if !dm.preview.is_empty() {
        let previews: Vec<Value> = dm
            .preview
            .iter()
            .map(|p| {
                json!({
                    "url": p.url.clone().unwrap_or_default(),
                    "title": p.title.clone().unwrap_or_default(),
                    "description": p.description.clone().unwrap_or_default(),
                    "date": p.date,
                    "image": p.image.as_ref().map(attachment_json),
                })
            })
            .collect();
        put(&mut m, "previews", previews);
    }
    if let Some(s) = &dm.sticker {
        put(
            &mut m,
            "sticker",
            json!({
                "packId": hex::encode(s.pack_id.as_deref().unwrap_or_default()),
                "stickerId": s.sticker_id.unwrap_or_default(),
                "emoji": s.emoji,
                "attachment": s.data.as_ref().map(attachment_json),
            }),
        );
    }
    if let Some(d) = &dm.delete {
        put(&mut m, "remoteDelete", json!({"timestamp": d.target_sent_timestamp.unwrap_or_default()}));
    }
    if !dm.contact.is_empty() {
        put(&mut m, "contacts", dm.contact.iter().map(shared_contact_json).collect::<Vec<_>>());
    }
    if let Some(p) = dm.payment.as_ref().and_then(payment_json) {
        put(&mut m, "payment", p);
    }
    if let Some(sc) = &dm.story_context {
        let mut sm = Map::new();
        if let Some(uuid) = uuid_from(sc.author_aci.as_deref(), sc.author_aci_binary.as_deref()) {
            let (_, number, uuid) = address(lookup, &uuid);
            put(&mut sm, "authorNumber", number);
            put(&mut sm, "authorUuid", uuid);
        }
        put(&mut sm, "sentTimestamp", sc.sent_timestamp.unwrap_or_default());
        put(&mut m, "storyContext", Value::Object(sm));
    }
    if let Some(g) = &dm.group_call_update {
        put(&mut m, "groupCallUpdate", json!({"eraId": g.era_id}));
    }
    if let Some(p) = &dm.poll_create {
        put(
            &mut m,
            "pollCreate",
            json!({
                "question": p.question.clone().unwrap_or_default(),
                "allowMultiple": p.allow_multiple.unwrap_or(false),
                "options": p.options,
            }),
        );
    }
    if let Some(v) = &dm.poll_vote {
        let mut vm = Map::new();
        author_fields(&mut vm, "author", uuid_from(None, v.target_author_aci_binary.as_deref()), lookup);
        put(&mut vm, "targetSentTimestamp", v.target_sent_timestamp.unwrap_or_default());
        put(&mut vm, "optionIndexes", v.option_indexes.clone());
        put(&mut vm, "voteCount", v.vote_count.unwrap_or_default());
        put(&mut m, "pollVote", Value::Object(vm));
    }
    if let Some(t) = &dm.poll_terminate {
        put(&mut m, "pollTerminate", json!({"targetSentTimestamp": t.target_sent_timestamp.unwrap_or_default()}));
    }
    if let Some(p) = &dm.pin_message {
        let mut pm = Map::new();
        author_fields(&mut pm, "targetAuthor", uuid_from(None, p.target_author_aci_binary.as_deref()), lookup);
        put(&mut pm, "targetSentTimestamp", p.target_sent_timestamp.unwrap_or_default());
        let duration: i64 = match p.pin_duration {
            Some(data_message::pin_message::PinDuration::PinDurationSeconds(s)) if s > 0 => s as i64,
            _ => -1,
        };
        put(&mut pm, "pinDurationSeconds", duration);
        put(&mut m, "pinMessage", Value::Object(pm));
    }
    if let Some(u) = &dm.unpin_message {
        let mut um = Map::new();
        author_fields(&mut um, "targetAuthor", uuid_from(None, u.target_author_aci_binary.as_deref()), lookup);
        put(&mut um, "targetSentTimestamp", u.target_sent_timestamp.unwrap_or_default());
        put(&mut m, "unpinMessage", Value::Object(um));
    }
    if let Some(a) = &dm.admin_delete {
        let mut am = Map::new();
        author_fields(&mut am, "targetAuthor", uuid_from(None, a.target_author_aci_binary.as_deref()), lookup);
        put(&mut am, "targetSentTimestamp", a.target_sent_timestamp.unwrap_or_default());
        put(&mut m, "adminDelete", Value::Object(am));
    }
    m
}

fn edit_message_json(em: &EditMessage, lookup: &dyn Lookup) -> Option<Value> {
    let dm = em.data_message.as_ref()?;
    Some(json!({
        "targetSentTimestamp": em.target_sent_timestamp.unwrap_or_default(),
        "dataMessage": data_message_json(dm, lookup, 0),
    }))
}

fn read_list_json(items: impl Iterator<Item = (Option<Uuid>, Option<u64>)>, lookup: &dyn Lookup) -> Vec<Value> {
    items
        .filter_map(|(uuid, ts)| {
            let (sender, number, uuid) = address(lookup, &uuid?);
            Some(json!({
                "sender": sender,
                "senderNumber": number,
                "senderUuid": uuid,
                "timestamp": ts.unwrap_or_default(),
            }))
        })
        .collect()
}

fn message_request_type(t: i32) -> &'static str {
    use sync_message::message_request_response::Type;
    match Type::try_from(t).unwrap_or(Type::Unknown) {
        Type::Unknown => "UNKNOWN",
        Type::Accept => "ACCEPT",
        Type::Delete => "DELETE",
        Type::Block => "BLOCK",
        Type::BlockAndDelete => "BLOCK_AND_DELETE",
        Type::Spam => "SPAM",
        Type::BlockAndSpam => "BLOCK_AND_SPAM",
    }
}

fn sent_message_json(sent: &sync_message::Sent, lookup: &dyn Lookup) -> Option<Value> {
    let mut m = if let Some(dm) = &sent.message {
        data_message_map(dm, lookup, sent.timestamp.unwrap_or_default())
    } else if sent.edit_message.is_some() {
        let mut m = Map::new();
        put(&mut m, "timestamp", sent.timestamp.unwrap_or_default());
        m
    } else {
        return None;
    };
    let destination = sent.parse_destination_service_id();
    let (dest, dest_number, dest_uuid) = match &destination {
        Some(id) => {
            let (d, n, u) = service_address(lookup, id);
            (Some(d), n, Some(u))
        }
        None => (None, None, None),
    };
    put(&mut m, "destination", dest);
    put(&mut m, "destinationNumber", dest_number);
    put(&mut m, "destinationUuid", dest_uuid);
    if let Some(em) = &sent.edit_message {
        if let Some(edit) = edit_message_json(em, lookup) {
            put(&mut m, "editMessage", edit);
        }
    }
    Some(Value::Object(m))
}

/// signal-cli's `JsonSyncMessage`. `None` when nothing in it maps to a field.
fn sync_message_json(sm: &SyncMessage, lookup: &dyn Lookup) -> Option<Value> {
    let mut m = Map::new();
    match &sm.content {
        Some(SyncContent::Sent(sent)) => {
            if let Some(v) = sent_message_json(sent, lookup) {
                put(&mut m, "sentMessage", v);
            }
        }
        Some(SyncContent::Blocked(b)) => {
            let mut numbers: Vec<String> = b.numbers.clone();
            let acis = b
                .acis_binary
                .iter()
                .filter_map(|x| Uuid::from_slice(x).ok())
                .chain(b.acis.iter().filter_map(|s| Uuid::parse_str(s).ok()));
            for aci in acis {
                let id = lookup.number_of(&aci).unwrap_or_else(|| aci.to_string());
                if !numbers.contains(&id) {
                    numbers.push(id);
                }
            }
            put(&mut m, "blockedNumbers", numbers);
            put(
                &mut m,
                "blockedGroupIds",
                b.group_ids.iter().map(|g| B64.encode(g)).collect::<Vec<_>>(),
            );
        }
        Some(SyncContent::ViewOnceOpen(v)) => {
            if let Some(uuid) = uuid_from(v.sender_aci.as_deref(), v.sender_aci_binary.as_deref()) {
                let (sender, number, uuid) = address(lookup, &uuid);
                put(
                    &mut m,
                    "viewOnceOpen",
                    json!({
                        "sender": sender,
                        "senderNumber": number,
                        "senderUuid": uuid,
                        "timestamp": v.timestamp.unwrap_or_default(),
                    }),
                );
            }
        }
        Some(SyncContent::MessageRequestResponse(r)) => {
            let mut rm = Map::new();
            put(&mut rm, "type", message_request_type(r.r#type.unwrap_or_default()));
            put_opt(&mut rm, "groupId", r.group_id.as_ref().map(|g| B64.encode(g)));
            if let Some(uuid) = uuid_from(r.thread_aci.as_deref(), r.thread_aci_binary.as_deref()) {
                let (_, number, uuid) = address(lookup, &uuid);
                put(&mut rm, "threadNumber", number);
                put(&mut rm, "threadUuid", uuid);
            }
            put(&mut m, "messageRequestResponse", Value::Object(rm));
        }
        Some(SyncContent::Contacts(_)) => put(&mut m, "type", "CONTACTS_SYNC"),
        Some(SyncContent::Request(_)) => put(&mut m, "type", "REQUEST_SYNC"),
        _ => {}
    }
    if !sm.read.is_empty() {
        let items = sm
            .read
            .iter()
            .map(|r| (uuid_from(r.sender_aci.as_deref(), r.sender_aci_binary.as_deref()), r.timestamp));
        put(&mut m, "readMessages", read_list_json(items, lookup));
    }
    if !sm.viewed.is_empty() {
        let items = sm
            .viewed
            .iter()
            .map(|r| (uuid_from(r.sender_aci.as_deref(), r.sender_aci_binary.as_deref()), r.timestamp));
        put(&mut m, "viewedMessages", read_list_json(items, lookup));
    }
    (!m.is_empty()).then_some(Value::Object(m))
}

fn receipt_json(rm: &ReceiptMessage, when: u64) -> Value {
    use proto::receipt_message::Type;
    let t = rm.r#type.and_then(|t| Type::try_from(t).ok()).unwrap_or(Type::Delivery);
    json!({
        "when": when,
        "isDelivery": t == Type::Delivery,
        "isRead": t == Type::Read,
        "isViewed": t == Type::Viewed,
        "timestamps": rm.timestamp,
    })
}

fn typing_json(tm: &TypingMessage, fallback_timestamp: u64) -> Value {
    use proto::typing_message::Action;
    let action = match tm.action.and_then(|a| Action::try_from(a).ok()) {
        Some(Action::Stopped) => "STOPPED",
        _ => "STARTED",
    };
    let mut m = Map::new();
    put(&mut m, "action", action);
    put(&mut m, "timestamp", tm.timestamp.unwrap_or(fallback_timestamp));
    put_opt(
        &mut m,
        "groupId",
        tm.group_id.as_ref().filter(|g| !g.is_empty()).map(|g| B64.encode(g)),
    );
    Value::Object(m)
}

/// Every attachment pointer in a message that should be downloaded on receipt: attachments,
/// quote thumbnails, preview images, shared contact avatars (also inside edits and sync
/// transcripts). Stickers are handled separately.
pub fn downloadable_attachments(body: &ContentBody) -> Vec<&AttachmentPointer> {
    fn from_data<'a>(dm: &'a DataMessage, out: &mut Vec<&'a AttachmentPointer>) {
        out.extend(dm.attachments.iter());
        if let Some(q) = &dm.quote {
            out.extend(q.attachments.iter().filter_map(|a| a.thumbnail.as_ref()));
        }
        out.extend(dm.preview.iter().filter_map(|p| p.image.as_ref()));
        out.extend(
            dm.contact
                .iter()
                .filter_map(|c| c.avatar.as_ref().and_then(|a| a.avatar.as_ref())),
        );
    }
    let mut out = Vec::new();
    match body {
        ContentBody::DataMessage(dm) => from_data(dm, &mut out),
        ContentBody::EditMessage(em) => {
            if let Some(dm) = &em.data_message {
                from_data(dm, &mut out);
            }
        }
        ContentBody::SynchronizeMessage(SyncMessage {
            content: Some(SyncContent::Sent(sent)),
            ..
        }) => {
            if let Some(dm) = &sent.message {
                from_data(dm, &mut out);
            }
            if let Some(dm) = sent.edit_message.as_ref().and_then(|e| e.data_message.as_ref()) {
                from_data(dm, &mut out);
            }
        }
        _ => {}
    }
    out
}

/// The sticker of a message (or of our own message from another device).
pub fn sticker_of(body: &ContentBody) -> Option<&data_message::Sticker> {
    match body {
        ContentBody::DataMessage(dm) => dm.sticker.as_ref(),
        ContentBody::SynchronizeMessage(SyncMessage {
            content: Some(SyncContent::Sent(sync_message::Sent { message: Some(dm), .. })),
            ..
        }) => dm.sticker.as_ref(),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;
    use presage::libsignal_service::content::Metadata;
    use presage::libsignal_service::protocol::Aci;
    use std::collections::HashMap;

    const ALICE: &str = "11111111-1111-4111-8111-111111111111";
    const BOB: &str = "22222222-2222-4222-8222-222222222222";
    const ME: &str = "33333333-3333-4333-8333-333333333333";
    const ALICE_NUMBER: &str = "+15550000001";
    const ME_NUMBER: &str = "+15550000003";
    const MASTER_KEY: [u8; 32] = [7u8; 32];

    struct TestLookup {
        numbers: HashMap<Uuid, String>,
    }

    impl Lookup for TestLookup {
        fn number_of(&self, uuid: &Uuid) -> Option<String> {
            self.numbers.get(uuid).cloned()
        }
        fn group_name(&self, master_key: &[u8]) -> Option<String> {
            (master_key == MASTER_KEY).then(|| "Climbing".to_owned())
        }
    }

    fn lookup() -> TestLookup {
        let mut numbers = HashMap::new();
        numbers.insert(Uuid::parse_str(ALICE).unwrap(), ALICE_NUMBER.to_owned());
        numbers.insert(Uuid::parse_str(ME).unwrap(), ME_NUMBER.to_owned());
        TestLookup { numbers }
    }

    fn aci(s: &str) -> ServiceId {
        Aci::from(Uuid::parse_str(s).unwrap()).into()
    }

    fn content(sender: &str, device: u32, body: ContentBody) -> Content {
        let ts = chrono::Utc.timestamp_millis_opt(1_700_000_000_000).unwrap();
        Content {
            metadata: Metadata {
                sender: aci(sender),
                destination: aci(ME),
                sender_device: device.try_into().unwrap(),
                server_guid: None,
                client_timestamp: ts,
                server_timestamp: chrono::Utc.timestamp_millis_opt(1_700_000_000_500).unwrap(),
                needs_receipt: true,
                unidentified_sender: true,
                was_plaintext: false,
                pni_verified: None,
            },
            body,
        }
    }

    fn env(c: &Content) -> Value {
        envelope_json(c, &lookup(), Some("Alice A"), 1_700_000_001_000).expect("mapped")
    }

    fn pointer(key: &str, ct: &str) -> AttachmentPointer {
        AttachmentPointer {
            attachment_identifier: Some(attachment_pointer::AttachmentIdentifier::CdnKey(key.into())),
            content_type: Some(ct.into()),
            key: Some(vec![1; 64]),
            size: Some(1234),
            digest: Some(vec![2; 32]),
            file_name: Some("photo.jpg".into()),
            width: Some(640),
            height: Some(480),
            upload_timestamp: Some(1_699_999_999_000),
            cdn_number: Some(3),
            ..Default::default()
        }
    }

    fn uuid_bytes(s: &str) -> Vec<u8> {
        Uuid::parse_str(s).unwrap().as_bytes().to_vec()
    }

    #[test]
    fn text_message_envelope() {
        let dm = DataMessage {
            body: Some("Hi \u{fffc}!".into()),
            timestamp: Some(1_700_000_000_000),
            expire_timer: Some(3600),
            body_ranges: vec![
                BodyRange {
                    start: Some(3),
                    length: Some(1),
                    associated_value: Some(body_range::AssociatedValue::MentionAciBinary(uuid_bytes(BOB))),
                },
                BodyRange {
                    start: Some(0),
                    length: Some(2),
                    associated_value: Some(body_range::AssociatedValue::Style(body_range::Style::Bold as i32)),
                },
            ],
            ..Default::default()
        };
        let v = env(&content(ALICE, 1, ContentBody::DataMessage(dm)));
        assert_eq!(
            v,
            json!({
                "source": ALICE_NUMBER,
                "sourceNumber": ALICE_NUMBER,
                "sourceUuid": ALICE,
                "sourceName": "Alice A",
                "sourceDevice": 1,
                "timestamp": 1_700_000_000_000u64,
                "serverReceivedTimestamp": 1_700_000_000_500u64,
                "serverDeliveredTimestamp": 1_700_000_001_000u64,
                "dataMessage": {
                    "timestamp": 1_700_000_000_000u64,
                    "message": "Hi \u{fffc}!",
                    "expiresInSeconds": 3600,
                    "viewOnce": false,
                    "mentions": [{"name": BOB, "number": null, "uuid": BOB, "start": 3, "length": 1}],
                    "textStyles": [{"style": "BOLD", "start": 0, "length": 2}],
                }
            })
        );
    }

    #[test]
    fn unknown_sender_has_null_number() {
        let v = env(&content(BOB, 2, ContentBody::DataMessage(DataMessage {
            body: Some("x".into()),
            ..Default::default()
        })));
        assert_eq!(v["source"], BOB);
        assert_eq!(v["sourceNumber"], Value::Null);
        assert_eq!(v["sourceUuid"], BOB);
        assert_eq!(v["sourceDevice"], 2);
        // falls back to the envelope timestamp
        assert_eq!(v["dataMessage"]["timestamp"], 1_700_000_000_000u64);
        assert_eq!(v["dataMessage"]["message"], "x");
    }

    #[test]
    fn attachments_previews_and_quote() {
        let mut voice = pointer("voiceKey_1", "audio/aac");
        voice.flags = Some(attachment_pointer::Flags::VoiceMessage as u32);
        voice.file_name = None;
        let dm = DataMessage {
            body: Some("see https://example.org".into()),
            timestamp: Some(5),
            attachments: vec![pointer("abcDEF-12_x", "image/jpeg"), voice],
            preview: vec![proto::Preview {
                url: Some("https://example.org".into()),
                title: Some("Example".into()),
                description: Some("desc".into()),
                image: Some(pointer("prevKey", "image/png")),
                date: None,
            }],
            quote: Some(data_message::Quote {
                id: Some(4),
                author_aci_binary: Some(uuid_bytes(ALICE)),
                text: Some("earlier".into()),
                attachments: vec![data_message::quote::QuotedAttachment {
                    content_type: Some("image/jpeg".into()),
                    file_name: Some("a.jpg".into()),
                    thumbnail: None,
                }],
                ..Default::default()
            }),
            ..Default::default()
        };
        let v = env(&content(ALICE, 1, ContentBody::DataMessage(dm)));
        let d = &v["dataMessage"];
        assert_eq!(
            d["attachments"][0],
            json!({
                "contentType": "image/jpeg",
                "filename": "photo.jpg",
                "id": "abcDEF-12_x.jpg",
                "size": 1234,
                "width": 640,
                "height": 480,
                "uploadTimestamp": 1_699_999_999_000u64,
            })
        );
        assert_eq!(d["attachments"][1]["id"], "voiceKey_1.aac");
        assert_eq!(d["attachments"][1]["voiceNote"], true);
        assert_eq!(d["attachments"][1]["filename"], Value::Null);
        assert_eq!(d["previews"][0]["url"], "https://example.org");
        assert_eq!(d["previews"][0]["title"], "Example");
        assert_eq!(d["previews"][0]["description"], "desc");
        assert_eq!(d["previews"][0]["image"]["id"], "prevKey.png");
        assert_eq!(d["previews"][0]["image"]["contentType"], "image/png");
        assert_eq!(
            d["quote"],
            json!({
                "id": 4,
                "author": ALICE_NUMBER,
                "authorNumber": ALICE_NUMBER,
                "authorUuid": ALICE,
                "text": "earlier",
                "mentions": [],
                "attachments": [{"contentType": "image/jpeg", "filename": "a.jpg", "thumbnail": null}],
            })
        );
    }

    #[test]
    fn group_message_with_sticker() {
        let dm = DataMessage {
            timestamp: Some(9),
            group_v2: Some(GroupContextV2 {
                master_key: Some(MASTER_KEY.to_vec()),
                revision: Some(12),
                group_change: None,
            }),
            sticker: Some(data_message::Sticker {
                pack_id: Some(vec![0xab, 0xcd]),
                pack_key: Some(vec![0; 32]),
                sticker_id: Some(3),
                data: Some(pointer("stk", "image/webp")),
                emoji: Some("🙂".into()),
            }),
            ..Default::default()
        };
        let v = env(&content(ALICE, 1, ContentBody::DataMessage(dm)));
        let d = &v["dataMessage"];
        let gid = group_id_from_master_key(&MASTER_KEY).unwrap();
        assert_eq!(B64.decode(&gid).unwrap().len(), 32);
        assert_eq!(
            d["groupInfo"],
            json!({"groupId": gid, "groupName": "Climbing", "revision": 12, "type": "DELIVER"})
        );
        assert_eq!(d["sticker"]["packId"], "abcd");
        assert_eq!(d["sticker"]["stickerId"], 3);
        assert_eq!(d["message"], Value::Null);
    }

    #[test]
    fn timer_update_in_group() {
        let dm = DataMessage {
            timestamp: Some(9),
            expire_timer: Some(604800),
            flags: Some(data_message::Flags::ExpirationTimerUpdate as u32),
            group_v2: Some(GroupContextV2 {
                master_key: Some(MASTER_KEY.to_vec()),
                revision: Some(13),
                group_change: Some(vec![1, 2, 3]),
            }),
            ..Default::default()
        };
        let d = &env(&content(ALICE, 1, ContentBody::DataMessage(dm)))["dataMessage"];
        assert_eq!(d["isExpirationUpdate"], true);
        assert_eq!(d["expiresInSeconds"], 604800);
        assert_eq!(d["groupInfo"]["type"], "UPDATE");
    }

    #[test]
    fn reaction_delete_pin_poll() {
        let reaction = DataMessage {
            timestamp: Some(10),
            reaction: Some(data_message::Reaction {
                emoji: Some("👍".into()),
                remove: Some(false),
                target_author_aci: Some(ME.into()),
                target_sent_timestamp: Some(8),
                target_author_aci_binary: None,
            }),
            ..Default::default()
        };
        let d = &env(&content(ALICE, 1, ContentBody::DataMessage(reaction)))["dataMessage"];
        assert_eq!(
            d["reaction"],
            json!({
                "emoji": "👍",
                "targetAuthor": ME_NUMBER,
                "targetAuthorNumber": ME_NUMBER,
                "targetAuthorUuid": ME,
                "targetSentTimestamp": 8,
                "isRemove": false,
            })
        );

        let delete = DataMessage {
            timestamp: Some(11),
            delete: Some(data_message::Delete { target_sent_timestamp: Some(8) }),
            ..Default::default()
        };
        let d = &env(&content(ALICE, 1, ContentBody::DataMessage(delete)))["dataMessage"];
        assert_eq!(d["remoteDelete"], json!({"timestamp": 8}));

        let pin = DataMessage {
            timestamp: Some(12),
            pin_message: Some(data_message::PinMessage {
                target_author_aci_binary: Some(uuid_bytes(BOB)),
                target_sent_timestamp: Some(8),
                pin_duration: Some(data_message::pin_message::PinDuration::PinDurationSeconds(86400)),
            }),
            ..Default::default()
        };
        let d = &env(&content(ALICE, 1, ContentBody::DataMessage(pin)))["dataMessage"];
        assert_eq!(
            d["pinMessage"],
            json!({
                "targetAuthor": BOB,
                "targetAuthorNumber": null,
                "targetAuthorUuid": BOB,
                "targetSentTimestamp": 8,
                "pinDurationSeconds": 86400,
            })
        );
        let forever = DataMessage {
            pin_message: Some(data_message::PinMessage {
                target_author_aci_binary: Some(uuid_bytes(BOB)),
                target_sent_timestamp: Some(8),
                pin_duration: Some(data_message::pin_message::PinDuration::PinDurationForever(true)),
            }),
            unpin_message: None,
            ..Default::default()
        };
        let d = &env(&content(ALICE, 1, ContentBody::DataMessage(forever)))["dataMessage"];
        assert_eq!(d["pinMessage"]["pinDurationSeconds"], -1);
        let unpin = DataMessage {
            unpin_message: Some(data_message::UnpinMessage {
                target_author_aci_binary: Some(uuid_bytes(ALICE)),
                target_sent_timestamp: Some(8),
            }),
            ..Default::default()
        };
        let d = &env(&content(ALICE, 1, ContentBody::DataMessage(unpin)))["dataMessage"];
        assert_eq!(d["unpinMessage"]["targetAuthorNumber"], ALICE_NUMBER);
        assert_eq!(d["unpinMessage"]["targetSentTimestamp"], 8);

        let create = DataMessage {
            poll_create: Some(data_message::PollCreate {
                question: Some("Lunch?".into()),
                allow_multiple: Some(false),
                options: vec!["Yes".into(), "No".into()],
            }),
            ..Default::default()
        };
        let d = &env(&content(ALICE, 1, ContentBody::DataMessage(create)))["dataMessage"];
        assert_eq!(d["pollCreate"], json!({"question": "Lunch?", "allowMultiple": false, "options": ["Yes", "No"]}));
        let vote = DataMessage {
            poll_vote: Some(data_message::PollVote {
                target_author_aci_binary: Some(uuid_bytes(ALICE)),
                target_sent_timestamp: Some(20),
                option_indexes: vec![1],
                vote_count: Some(2),
            }),
            ..Default::default()
        };
        let d = &env(&content(BOB, 1, ContentBody::DataMessage(vote)))["dataMessage"];
        assert_eq!(
            d["pollVote"],
            json!({
                "author": ALICE_NUMBER,
                "authorNumber": ALICE_NUMBER,
                "authorUuid": ALICE,
                "targetSentTimestamp": 20,
                "optionIndexes": [1],
                "voteCount": 2,
            })
        );
        let end = DataMessage {
            poll_terminate: Some(data_message::PollTerminate { target_sent_timestamp: Some(20) }),
            ..Default::default()
        };
        let d = &env(&content(ALICE, 1, ContentBody::DataMessage(end)))["dataMessage"];
        assert_eq!(d["pollTerminate"], json!({"targetSentTimestamp": 20}));
    }

    #[test]
    fn view_once_story_context_payment_contacts() {
        let dm = DataMessage {
            is_view_once: Some(true),
            attachments: vec![pointer("vo", "image/jpeg")],
            story_context: Some(data_message::StoryContext {
                author_aci: None,
                sent_timestamp: Some(77),
                author_aci_binary: Some(uuid_bytes(ALICE)),
            }),
            payment: Some(data_message::Payment {
                item: Some(data_message::payment::Item::Notification(
                    data_message::payment::Notification {
                        transaction: None,
                        note: Some("for pizza".into()),
                    },
                )),
            }),
            contact: vec![data_message::Contact {
                name: Some(data_message::contact::Name {
                    given_name: Some("Carol".into()),
                    family_name: Some("C".into()),
                    nickname: Some("Caz".into()),
                    ..Default::default()
                }),
                number: vec![data_message::contact::Phone {
                    value: Some("+15550000009".into()),
                    r#type: Some(data_message::contact::phone::Type::Mobile as i32),
                    label: None,
                }],
                email: vec![],
                address: vec![data_message::contact::PostalAddress {
                    r#type: Some(data_message::contact::postal_address::Type::Work as i32),
                    city: Some("Brno".into()),
                    ..Default::default()
                }],
                avatar: Some(data_message::contact::Avatar {
                    avatar: Some(pointer("cav", "image/jpeg")),
                    is_profile: Some(false),
                }),
                organization: Some("Org".into()),
            }],
            ..Default::default()
        };
        let d = &env(&content(ALICE, 1, ContentBody::DataMessage(dm)))["dataMessage"];
        assert_eq!(d["viewOnce"], true);
        assert_eq!(d["storyContext"], json!({"authorNumber": ALICE_NUMBER, "authorUuid": ALICE, "sentTimestamp": 77}));
        assert_eq!(d["payment"], json!({"note": "for pizza", "receipt": null}));
        let c = &d["contacts"][0];
        assert_eq!(c["name"]["given"], "Carol");
        assert_eq!(c["name"]["nickname"], "Caz");
        assert_eq!(c["phone"][0], json!({"value": "+15550000009", "type": "MOBILE", "label": null}));
        assert_eq!(c["address"][0]["type"], "WORK");
        assert_eq!(c["address"][0]["city"], "Brno");
        assert_eq!(c["avatar"]["attachment"]["id"], "cav.jpg");
        assert_eq!(c["organization"], "Org");
    }

    #[test]
    fn incoming_edit() {
        let em = EditMessage {
            target_sent_timestamp: Some(100),
            data_message: Some(DataMessage {
                body: Some("fixed".into()),
                timestamp: Some(200),
                ..Default::default()
            }),
        };
        let v = env(&content(ALICE, 1, ContentBody::EditMessage(em)));
        assert!(v.get("dataMessage").is_none());
        assert_eq!(v["editMessage"]["targetSentTimestamp"], 100);
        assert_eq!(v["editMessage"]["dataMessage"]["message"], "fixed");
        assert_eq!(v["editMessage"]["dataMessage"]["timestamp"], 200);
    }

    #[test]
    fn sync_sent_transcripts() {
        let sent = sync_message::Sent {
            destination_service_id_binary: Some(uuid_bytes(ALICE)),
            timestamp: Some(300),
            message: Some(DataMessage {
                body: Some("from phone".into()),
                timestamp: Some(300),
                ..Default::default()
            }),
            ..Default::default()
        };
        let sm = SyncMessage {
            content: Some(SyncContent::Sent(sent)),
            ..Default::default()
        };
        let v = env(&content(ME, 1, ContentBody::SynchronizeMessage(sm)));
        assert_eq!(v["source"], ME_NUMBER);
        let s = &v["syncMessage"]["sentMessage"];
        assert_eq!(s["message"], "from phone");
        assert_eq!(s["timestamp"], 300);
        assert_eq!(s["destination"], ALICE_NUMBER);
        assert_eq!(s["destinationNumber"], ALICE_NUMBER);
        assert_eq!(s["destinationUuid"], ALICE);

        let edit = sync_message::Sent {
            destination_service_id: Some(BOB.into()),
            timestamp: Some(400),
            edit_message: Some(EditMessage {
                target_sent_timestamp: Some(300),
                data_message: Some(DataMessage {
                    body: Some("edited".into()),
                    timestamp: Some(400),
                    ..Default::default()
                }),
            }),
            ..Default::default()
        };
        let sm = SyncMessage {
            content: Some(SyncContent::Sent(edit)),
            ..Default::default()
        };
        let v = env(&content(ME, 1, ContentBody::SynchronizeMessage(sm)));
        let s = &v["syncMessage"]["sentMessage"];
        assert_eq!(s["destination"], BOB);
        assert_eq!(s["destinationNumber"], Value::Null);
        assert_eq!(s["editMessage"]["targetSentTimestamp"], 300);
        assert_eq!(s["editMessage"]["dataMessage"]["message"], "edited");
        assert!(s.get("message").is_none());
    }

    #[test]
    fn other_sync_messages() {
        let sm = SyncMessage {
            read: vec![sync_message::Read {
                sender_aci: None,
                timestamp: Some(5),
                sender_aci_binary: Some(uuid_bytes(ALICE)),
            }],
            viewed: vec![sync_message::Viewed {
                sender_aci: Some(BOB.into()),
                timestamp: Some(6),
                sender_aci_binary: None,
            }],
            ..Default::default()
        };
        let v = env(&content(ME, 2, ContentBody::SynchronizeMessage(sm)));
        assert_eq!(
            v["syncMessage"],
            json!({
                "readMessages": [{"sender": ALICE_NUMBER, "senderNumber": ALICE_NUMBER, "senderUuid": ALICE, "timestamp": 5}],
                "viewedMessages": [{"sender": BOB, "senderNumber": null, "senderUuid": BOB, "timestamp": 6}],
            })
        );

        let blocked = SyncMessage {
            content: Some(SyncContent::Blocked(sync_message::Blocked {
                numbers: vec!["+15550000008".into()],
                acis: vec![],
                group_ids: vec![vec![1, 2, 3]],
                acis_binary: vec![uuid_bytes(BOB)],
            })),
            ..Default::default()
        };
        let v = env(&content(ME, 1, ContentBody::SynchronizeMessage(blocked)));
        assert_eq!(v["syncMessage"]["blockedNumbers"], json!(["+15550000008", BOB]));
        assert_eq!(v["syncMessage"]["blockedGroupIds"], json!(["AQID"]));

        let vo = SyncMessage {
            content: Some(SyncContent::ViewOnceOpen(sync_message::ViewOnceOpen {
                sender_aci: Some(ALICE.into()),
                timestamp: Some(9),
                sender_aci_binary: None,
            })),
            ..Default::default()
        };
        let v = env(&content(ME, 1, ContentBody::SynchronizeMessage(vo)));
        assert_eq!(v["syncMessage"]["viewOnceOpen"]["senderNumber"], ALICE_NUMBER);
        assert_eq!(v["syncMessage"]["viewOnceOpen"]["timestamp"], 9);

        let mrr = SyncMessage {
            content: Some(SyncContent::MessageRequestResponse(sync_message::MessageRequestResponse {
                thread_aci: None,
                group_id: None,
                r#type: Some(sync_message::message_request_response::Type::Accept as i32),
                thread_aci_binary: Some(uuid_bytes(ALICE)),
            })),
            ..Default::default()
        };
        let v = env(&content(ME, 1, ContentBody::SynchronizeMessage(mrr)));
        assert_eq!(
            v["syncMessage"]["messageRequestResponse"],
            json!({"type": "ACCEPT", "threadNumber": ALICE_NUMBER, "threadUuid": ALICE})
        );

        let contacts = SyncMessage {
            content: Some(SyncContent::Contacts(sync_message::Contacts { blob: None, complete: Some(true) })),
            ..Default::default()
        };
        let v = env(&content(ME, 1, ContentBody::SynchronizeMessage(contacts)));
        assert_eq!(v["syncMessage"], json!({"type": "CONTACTS_SYNC"}));

        let keys = SyncMessage {
            content: Some(SyncContent::Keys(sync_message::Keys::default())),
            ..Default::default()
        };
        assert!(envelope_json(&content(ME, 1, ContentBody::SynchronizeMessage(keys)), &lookup(), None, 0).is_none());
    }

    #[test]
    fn receipts_and_typing() {
        let rm = ReceiptMessage {
            r#type: Some(proto::receipt_message::Type::Read as i32),
            timestamp: vec![1, 2],
        };
        let v = env(&content(ALICE, 1, ContentBody::ReceiptMessage(rm)));
        assert_eq!(
            v["receiptMessage"],
            json!({"when": 1_700_000_000_000u64, "isDelivery": false, "isRead": true, "isViewed": false, "timestamps": [1, 2]})
        );
        let delivery = ReceiptMessage { r#type: None, timestamp: vec![3] };
        let v = env(&content(ALICE, 1, ContentBody::ReceiptMessage(delivery)));
        assert_eq!(v["receiptMessage"]["isDelivery"], true);

        let tm = TypingMessage {
            timestamp: Some(42),
            action: Some(proto::typing_message::Action::Started as i32),
            group_id: Some(vec![9; 32]),
        };
        let v = env(&content(ALICE, 1, ContentBody::TypingMessage(tm)));
        assert_eq!(v["typingMessage"]["action"], "STARTED");
        assert_eq!(v["typingMessage"]["timestamp"], 42);
        assert_eq!(v["typingMessage"]["groupId"], B64.encode([9u8; 32]));
        let stop = TypingMessage {
            timestamp: Some(43),
            action: Some(proto::typing_message::Action::Stopped as i32),
            group_id: None,
        };
        let v = env(&content(ALICE, 1, ContentBody::TypingMessage(stop)));
        assert_eq!(v["typingMessage"], json!({"action": "STOPPED", "timestamp": 43}));
    }

    #[test]
    fn ignored_content() {
        let c = content(ALICE, 1, ContentBody::NullMessage(Default::default()));
        assert!(envelope_json(&c, &lookup(), None, 0).is_none());
    }

    #[test]
    fn attachment_ids_are_file_names() {
        let mut p = pointer("a/b+c=", "image/jpeg");
        assert_eq!(attachment_id(&p), "a_b_c_.jpg");
        p.attachment_identifier = Some(attachment_pointer::AttachmentIdentifier::CdnId(12345));
        p.content_type = Some("application/x-unknown-thing".into());
        p.file_name = Some("Report.PDF".into());
        assert_eq!(attachment_id(&p), "12345.pdf");
        p.attachment_identifier = None;
        p.file_name = None;
        assert_eq!(attachment_id(&p), hex::encode([2u8; 16]));
        assert!(crate::files::is_safe_file_name(&attachment_id(&p)));
    }

    #[test]
    fn collects_downloadable_attachments() {
        let dm = DataMessage {
            attachments: vec![pointer("a", "image/jpeg")],
            preview: vec![proto::Preview { image: Some(pointer("b", "image/png")), ..Default::default() }],
            quote: Some(data_message::Quote {
                attachments: vec![data_message::quote::QuotedAttachment {
                    thumbnail: Some(pointer("c", "image/jpeg")),
                    ..Default::default()
                }],
                ..Default::default()
            }),
            ..Default::default()
        };
        let sm = SyncMessage {
            content: Some(SyncContent::Sent(sync_message::Sent { message: Some(dm), ..Default::default() })),
            ..Default::default()
        };
        let body = ContentBody::SynchronizeMessage(sm);
        let ids: Vec<String> = downloadable_attachments(&body).into_iter().map(attachment_id).collect();
        assert_eq!(ids, vec!["a.jpg", "c.jpg", "b.png"]);
    }
}
