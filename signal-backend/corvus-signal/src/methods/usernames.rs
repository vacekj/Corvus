//! Own username and username link (used by updateAccount).

use serde_json::{Value, json};

use crate::ctx::Account;
use crate::rpc::{Method, RpcError, fail};

pub const METHODS: &[Method] = &[];

/// `nickname` is a full username (`name.42`) or a nickname, for which a free number is picked.
pub async fn set(a: &Account, nickname: &str) -> Result<Value, RpcError> {
    let confirmed = a.manager().set_username(nickname.trim()).await.map_err(fail)?;
    let username = confirmed.username.to_string();
    a.local().set_own_username(Some(&username)).await.map_err(fail)?;
    Ok(json!({"username": username, "usernameLink": confirmed.link().to_string()}))
}

pub async fn delete(a: &Account) -> Result<(), RpcError> {
    a.manager().delete_username().await.map_err(fail)?;
    a.local().set_own_username(None).await.map_err(fail)?;
    Ok(())
}
