//! Account-level privacy settings: phone number sharing, discoverability and
//! the other `AccountRecord` settings.

use libsignal_service::{
    profile_cipher::ProfileCipher,
    profile_name::ProfileName,
    storage_service::{AccountPatch, AccountRecordExt, PhoneNumberSharingMode, StorageState},
    websocket::profile_write::ProfileFields,
    AccountManager,
};

use crate::store::Store;
use crate::{Error, Manager};

use super::{Registered, RegistrationType};

impl<S: Store> Manager<S, Registered> {
    /// Changes `AccountRecord` settings (read receipts, typing indicators,
    /// link previews, pinned conversations, ...) and syncs them.
    pub async fn update_account_record(
        &mut self,
        patch: AccountPatch,
    ) -> Result<StorageState, Error<S::Error>> {
        self.update_storage(&[libsignal_service::storage_service::StorageChange::Account(
            patch,
        )])
        .await
    }

    /// Whether people who have our number can find us. Written to the
    /// `AccountRecord` (`unlistedPhoneNumber`); the primary device pushes it to
    /// the server. A primary registration also sets it with
    /// `PUT /v1/accounts/attributes` directly.
    pub async fn set_discoverable_by_phone_number(
        &mut self,
        discoverable: bool,
    ) -> Result<StorageState, Error<S::Error>> {
        let state = self
            .update_account_record(AccountPatch {
                unlisted_phone_number: Some(!discoverable),
                ..Default::default()
            })
            .await?;
        if self.registration_type() == RegistrationType::Primary {
            let mut account_manager = AccountManager::new(
                self.identified_push_service(),
                self.identified_websocket(false).await?,
                None,
            );
            super::set_account_attributes(&mut account_manager, &self.store, &self.state.data)
                .await?;
        }
        Ok(state)
    }

    /// Whether our profile shows our phone number: `AccountRecord`
    /// (`phoneNumberSharingMode`) plus a profile write carrying
    /// `phoneNumberSharing`.
    pub async fn set_phone_number_sharing(
        &mut self,
        share: bool,
    ) -> Result<StorageState, Error<S::Error>> {
        let mode = if share {
            PhoneNumberSharingMode::Everybody
        } else {
            PhoneNumberSharingMode::Nobody
        };
        let state = self
            .update_account_record(AccountPatch {
                phone_number_sharing_mode: Some(mode),
                ..Default::default()
            })
            .await?;
        self.rewrite_profile(None, Some(share)).await?;
        Ok(state)
    }

    /// Writes our profile name, about and emoji while keeping the avatar and
    /// the phone number sharing setting from the `AccountRecord` (a plain
    /// [`Manager::update_profile`] turns phone number sharing off).
    pub async fn update_profile_keeping_settings(
        &mut self,
        name: ProfileName<String>,
        about: Option<String>,
        about_emoji: Option<String>,
    ) -> Result<(), Error<S::Error>> {
        self.rewrite_profile(Some((name, about, about_emoji)), None)
            .await
    }

    /// Re-writes our profile. `fields` replaces name/about/emoji (else the
    /// current ones are kept); `share` overrides the phone number sharing
    /// setting (else it comes from the `AccountRecord`).
    async fn rewrite_profile(
        &mut self,
        fields: Option<(ProfileName<String>, Option<String>, Option<String>)>,
        share: Option<bool>,
    ) -> Result<(), Error<S::Error>> {
        let aci = self.state.data.service_ids.aci();
        let profile_key = self.state.data.profile_key;
        let account = self
            .storage_state()
            .await?
            .and_then(|state| state.account().cloned());
        let share = share.unwrap_or_else(|| {
            account
                .as_ref()
                .is_some_and(|a| a.phone_number_sharing() == PhoneNumberSharingMode::Everybody)
        });

        let mut websocket = self.identified_websocket(false).await?;
        let current = ProfileCipher::new(profile_key)
            .decrypt(websocket.retrieve_profile_by_id(aci, Some(profile_key)).await?)?;
        let (name, about, about_emoji) = match fields {
            Some(fields) => fields,
            None => {
                let name = current.name.clone().unwrap_or_else(|| ProfileName {
                    given_name: account
                        .as_ref()
                        .map(|a| a.given_name.clone())
                        .unwrap_or_default(),
                    family_name: account
                        .as_ref()
                        .map(|a| a.family_name.clone())
                        .filter(|f| !f.is_empty()),
                });
                (name, current.about.clone(), current.about_emoji.clone())
            }
        };

        websocket
            .write_profile_fields(
                aci,
                profile_key,
                ProfileFields {
                    name: name.as_ref(),
                    about: about.as_deref(),
                    about_emoji: about_emoji.as_deref(),
                    retain_avatar: current.avatar.is_some(),
                    phone_number_sharing: Some(share),
                },
            )
            .await?;

        let profile = ProfileCipher::new(profile_key)
            .decrypt(websocket.retrieve_profile_by_id(aci, Some(profile_key)).await?)?;
        let _ = self
            .store
            .save_profile(aci.into(), profile_key, profile)
            .await;
        Ok(())
    }
}
