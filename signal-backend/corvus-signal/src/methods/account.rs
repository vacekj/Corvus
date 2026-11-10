//! updateAccount: device name, username, phone number privacy.

use std::rc::Rc;

use serde_json::{Value, json};

use super::common::*;
use crate::ctx::Ctx;
use crate::method;
use crate::rpc::{Method, RpcError, fail};

pub const METHODS: &[Method] = &[method!("updateAccount", update_account)];

async fn update_account(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    let a = ctx.account()?;
    let mut result = json!({});
    if let Some(name) = str_param(&p, "deviceName").filter(|s| !s.is_empty()) {
        a.manager().update_device_name(&name).await.map_err(fail)?;
    }
    if bool_param(&p, "deleteUsername") {
        super::usernames::delete(a).await?;
    } else if let Some(u) = str_param(&p, "username").filter(|s| !s.is_empty()) {
        result = super::usernames::set(a, &u).await?;
    }
    if p.get("numberSharing").is_some() || p.get("discoverableByNumber").is_some() {
        let sharing = p.get("numberSharing").map(|_| bool_param(&p, "numberSharing"));
        let discoverable = p.get("discoverableByNumber").map(|_| bool_param(&p, "discoverableByNumber"));
        super::storage::set_number_privacy(a, sharing, discoverable).await?;
    }
    Ok(result)
}
