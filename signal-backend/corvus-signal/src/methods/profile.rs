//! updateProfile: own name, about, emoji and picture.

use std::rc::Rc;

use presage::libsignal_service::profile_name::ProfileName;
use serde_json::{Value, json};

use super::common::*;
use crate::ctx::Ctx;
use crate::method;
use crate::rpc::{Method, RpcError, fail};

pub const METHODS: &[Method] = &[method!("updateProfile", update_profile)];

async fn update_profile(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    let a = ctx.account()?;
    let mut mgr = a.manager();
    // The server replaces the whole profile, so start from the current one.
    let current = mgr
        .refresh_profile_by_uuid(a.aci, a.profile_key())
        .await
        .ok()
        .or(a.cached_profile(&a.aci).await);
    let (mut given, mut family) = current
        .as_ref()
        .and_then(|c| c.name.clone())
        .map(|n| (n.given_name, n.family_name.unwrap_or_default()))
        .unwrap_or_default();
    let mut about = current.as_ref().and_then(|c| c.about.clone()).unwrap_or_default();
    let mut emoji = current.as_ref().and_then(|c| c.about_emoji.clone()).unwrap_or_default();
    if let Some(v) = str_param(&p, "givenName").or_else(|| str_param(&p, "name")) {
        given = v;
    }
    if let Some(v) = str_param(&p, "familyName") {
        family = v;
    }
    if let Some(v) = str_param(&p, "about") {
        about = v;
    }
    if let Some(v) = str_param(&p, "aboutEmoji") {
        emoji = v;
    }
    if given.trim().is_empty() {
        return Err(RpcError::invalid_params("The profile name cannot be empty"));
    }
    let name = ProfileName {
        given_name: given,
        family_name: (!family.is_empty()).then_some(family),
    };
    let about = (!about.is_empty()).then_some(about);
    let emoji = (!emoji.is_empty()).then_some(emoji);

    let avatar = if bool_param(&p, "removeAvatar") {
        Some(Vec::new())
    } else if let Some(path) = str_param(&p, "avatar").filter(|s| !s.is_empty()) {
        Some(std::fs::read(&path).map_err(|e| RpcError::failed(format!("Cannot read {path}: {e}")))?)
    } else {
        None
    };
    match avatar {
        Some(bytes) => mgr
            .update_profile_with_avatar(name, about, emoji, Some(bytes))
            .await
            .map_err(fail)?,
        // keeps the avatar and the phone number sharing setting
        None => mgr.update_profile_keeping_settings(name, about, emoji).await.map_err(fail)?,
    }
    // Refresh the cached own picture for Corvus.
    let _ = crate::avatars::profile_avatar(a, &ctx.dir, &a.aci, true).await;
    a.invalidate_directory();
    Ok(json!({}))
}
