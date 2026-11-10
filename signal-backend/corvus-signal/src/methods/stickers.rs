//! listStickerPacks, getSticker, addStickerPack (pack creation is not supported).

use std::rc::Rc;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as B64;
use presage::store::ContentsStore;
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

async fn list_packs(ctx: Rc<Ctx>, _p: Value) -> Result<Value, RpcError> {
    let a = ctx.account()?;
    let mut out = Vec::new();
    for pack in a.store.sticker_packs().await.map_err(fail)?.filter_map(Result::ok) {
        let stickers: Vec<Value> = pack
            .manifest
            .stickers
            .iter()
            .map(|s| json!({"id": s.id, "emoji": s.emoji.clone().unwrap_or_default()}))
            .collect();
        out.push(json!({
            "packId": hex::encode(&pack.id),
            "title": pack.manifest.title,
            "author": pack.manifest.author,
            "installed": true,
            "stickers": stickers,
        }));
    }
    Ok(Value::Array(out))
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
    let key = match a.store.sticker_pack(&pack_id).await.map_err(fail)? {
        Some(pack) => pack.key,
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
