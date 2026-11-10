//! Own username and username link, kept in sync with the `AccountRecord`.

use libsignal_service::{
    protocol::Username,
    storage_service::{username_link_record, AccountPatch, AccountRecordExt},
    websocket::username_management::{generate_username_link, ConfirmedUsername},
};
use url::Url;

use crate::store::Store;
use crate::{Error, Manager};

use super::Registered;

impl<S: Store> Manager<S, Registered> {
    /// Sets our username. `requested` is either a full username (`name.42`)
    /// or a nickname, for which a free discriminator is picked. Also sets up
    /// the username link and records both in the `AccountRecord`.
    pub async fn set_username(
        &mut self,
        requested: &str,
    ) -> Result<ConfirmedUsername, Error<S::Error>> {
        let confirmed = self
            .identified_websocket(false)
            .await?
            .set_username(requested)
            .await?;
        self.update_account_record(AccountPatch {
            username: Some(confirmed.username.to_string()),
            username_link: Some(Some(username_link_record(
                confirmed.link_entropy,
                confirmed.link_handle,
            ))),
            ..Default::default()
        })
        .await?;
        Ok(confirmed)
    }

    /// Deletes our username and username link.
    pub async fn delete_username(&mut self) -> Result<(), Error<S::Error>> {
        self.identified_websocket(false)
            .await?
            .delete_username_hash()
            .await?;
        self.update_account_record(AccountPatch {
            username: Some(String::new()),
            username_link: Some(None),
            ..Default::default()
        })
        .await?;
        Ok(())
    }

    /// Replaces the username link with a new one (the old link stops
    /// working) and returns it.
    pub async fn reset_username_link(&mut self) -> Result<Url, Error<S::Error>> {
        let state = self.sync_storage_state_for_account().await?;
        let username = state
            .and_then(|account| Some(account.username).filter(|u| !u.is_empty()))
            .ok_or(libsignal_service::prelude::ServiceError::UsernameHashNotSet)?;
        let username = Username::new(&username)?;
        let (entropy, handle) = self
            .identified_websocket(false)
            .await?
            .set_username_link_parts(&username, false)
            .await?;
        self.update_account_record(AccountPatch {
            username_link: Some(Some(username_link_record(entropy, handle))),
            ..Default::default()
        })
        .await?;
        Ok(generate_username_link(handle, &entropy))
    }

    /// Our username and username link according to the last Storage Service
    /// snapshot (no network).
    pub async fn own_username(&self) -> Result<Option<(String, Option<Url>)>, Error<S::Error>> {
        let Some(state) = self.storage_state().await? else {
            return Ok(None);
        };
        Ok(state.account().and_then(|account| {
            (!account.username.is_empty()).then(|| {
                (
                    account.username.clone(),
                    account
                        .username_link_parts()
                        .map(|(entropy, handle)| generate_username_link(handle, &entropy)),
                )
            })
        }))
    }

    /// Resolves a `https://signal.me/#eu/...` link to the username it encodes.
    pub async fn lookup_username_link(
        &mut self,
        link: &Url,
    ) -> Result<Option<Username>, Error<S::Error>> {
        Ok(self
            .unidentified_websocket()
            .await?
            .look_up_username_link(link)
            .await?)
    }

    async fn sync_storage_state_for_account(
        &mut self,
    ) -> Result<Option<libsignal_service::proto::AccountRecord>, Error<S::Error>> {
        let state = match self.storage_state().await? {
            Some(state) if state.account().is_some() => state,
            _ => self.sync_storage_service().await?,
        };
        Ok(state.account().cloned())
    }
}
