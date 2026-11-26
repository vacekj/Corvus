//! listStickerPacks, getSticker, addStickerPack (pack creation is not supported).

use std::rc::Rc;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as B64;
use serde_json::{Value, json};

use super::common::*;
use crate::ctx::Ctx;
use crate::files::write_atomic;
use crate::method;
use crate::rpc::{Method, RpcError, fail};

pub const METHODS: &[Method] = &[
    method!("listStickerPacks", list_packs),
    method!("getSticker", get_sticker),
    method!("addStickerPack", add_pack),
    method!("uploadStickerPack", upload_pack),
];

/// Title, author and stickers of an installed pack, kept in the store: reading them from the manifest
/// (which holds every sticker image) took seconds at each start and held a database connection.
#[derive(serde::Serialize, serde::Deserialize, Clone)]
struct PackSummary {
    title: String,
    author: String,
    stickers: Vec<(u32, Option<String>)>,
}

async fn pack_summary(a: &crate::ctx::Account, id: &[u8]) -> Result<Option<PackSummary>, RpcError> {
    let key = format!("sticker-summary:{}", hex::encode(id));
    if let Some(s) = a.local().value::<Option<PackSummary>>(&key).await {
        return Ok(Some(s));
    }
    let Some((title, author, stickers)) = a.store.sticker_pack_summary(id).await.map_err(fail)? else {
        return Ok(None);
    };
    let stickers = serde_json::from_str::<Vec<(u32, Option<String>)>>(&stickers).unwrap_or_default();
    let s = PackSummary { title, author, stickers };
    let _ = a.local().set_value(&key, &Some(s.clone())).await; // a pack's manifest never changes
    Ok(Some(s))
}

async fn list_packs(ctx: Rc<Ctx>, _p: Value) -> Result<Value, RpcError> {
    let a = ctx.account()?;
    let ids = a.store.sticker_pack_ids().await.map_err(fail)?;
    if let Some(list) = PACKS.with(|c| c.borrow().as_ref().filter(|(k, _)| *k == ids).map(|(_, v)| v.clone())) {
        return Ok(list);
    }
    let mut out = Vec::new();
    for id in &ids {
        let Some(s) = pack_summary(a, id).await? else { continue };
        let stickers: Vec<Value> = s
            .stickers
            .into_iter()
            .map(|(id, emoji)| json!({"id": id, "emoji": emoji.unwrap_or_default()}))
            .collect();
        out.push(json!({
            "packId": hex::encode(id),
            "title": s.title,
            "author": s.author,
            "installed": true,
            "stickers": stickers,
        }));
    }
    let list = Value::Array(out);
    PACKS.with(|c| *c.borrow_mut() = Some((ids, list.clone())));
    Ok(list)
}

thread_local! {
    /// The last sticker pack list and the pack ids it was made for.
    static PACKS: std::cell::RefCell<Option<(Vec<Vec<u8>>, Value)>> = const { std::cell::RefCell::new(None) };
}

async fn get_sticker(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    let a = ctx.account()?;
    let pack_hex = req_str(&p, "packId")?.to_ascii_lowercase();
    let sticker_id = i64_param(&p, "stickerId")
        .filter(|i| *i >= 0)
        .ok_or_else(|| RpcError::invalid_params("missing parameter stickerId"))? as u32;
    let path = ctx.dir.sticker(&pack_hex, sticker_id);
    if let Some(bytes) = path.as_ref().and_then(|p| std::fs::read(p).ok()) {
        return Ok(json!({"data": B64.encode(bytes)}));
    }
    let pack_id = hex::decode(&pack_hex).map_err(|_| RpcError::invalid_params("bad packId"))?;
    let key = match a.store.sticker_pack_key(&pack_id).await.map_err(fail)? {
        Some(key) => key,
        None => a
            .local()
            .sticker_key(&pack_hex)
            .await
            .ok_or_else(|| RpcError::failed("Unknown sticker pack"))?,
    };
    let bytes = a.manager().fetch_sticker(&pack_id, &key, sticker_id).await.map_err(fail)?;
    if let Some(path) = path {
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = write_atomic(&path, &bytes);
    }
    Ok(json!({"data": B64.encode(bytes)}))
}

/// `https://signal.art/addstickers/#pack_id=…&pack_key=…` (or the sgnl:// form).
pub fn parse_pack_uri(uri: &str) -> Option<(Vec<u8>, Vec<u8>)> {
    let query = uri.split_once('#').map(|x| x.1).or_else(|| uri.split_once('?').map(|x| x.1))?;
    let mut id = None;
    let mut key = None;
    for part in query.split('&') {
        match part.split_once('=') {
            Some(("pack_id", v)) => id = hex::decode(v).ok(),
            Some(("pack_key", v)) => key = hex::decode(v).ok(),
            _ => {}
        }
    }
    Some((id?, key?))
}

async fn add_pack(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    let a = ctx.account()?;
    let uri = req_str(&p, "uri")?;
    let (id, key) = parse_pack_uri(&uri).ok_or_else(|| RpcError::invalid_params("Invalid sticker pack link"))?;
    a.local().set_sticker_key(&hex::encode(&id), &key).await.map_err(fail)?;
    a.manager().install_sticker_pack(&id, &key).await.map_err(fail)?;
    Ok(json!({}))
}

async fn upload_pack(_ctx: Rc<Ctx>, _p: Value) -> Result<Value, RpcError> {
    Err(RpcError::not_supported("Creating sticker packs"))
}

#[cfg(test)]
mod tests {
    #[test]
    fn pack_uri() {
        let id = "00".repeat(16);
        let key = "11".repeat(32);
        let (i, k) = super::parse_pack_uri(&format!("https://signal.art/addstickers/#pack_id={id}&pack_key={key}")).unwrap();
        assert_eq!((i.len(), k.len()), (16, 32));
        assert!(super::parse_pack_uri("https://signal.art/addstickers/#pack_id=zz").is_none());
    }
}
