//! Creating and changing groups on the group server. Adapted from
//! whisperfish/libsignal-service-rs#473 (Rafael Bachmann).
//! Signal-Android reference: `GroupsV2Api`.

use rand::{CryptoRng, Rng};
use zkgroup::{
    groups::{GroupMasterKey, GroupSecretParams},
    ServerPublicParams,
};

use super::{CredentialsCache, GroupsManager};
use crate::{
    groups_v2::{
        GroupDecodingError, GroupInviteLink, GroupJoinInfo, GroupOperations,
    },
    proto,
    push_service::ServiceError,
};

pub(crate) fn secret_params(
    master_key_bytes: &[u8],
) -> Result<GroupSecretParams, ServiceError> {
    let master_key = GroupMasterKey::new(
        master_key_bytes
            .try_into()
            .map_err(|_| ServiceError::GroupsV2Error)?,
    );
    Ok(GroupSecretParams::derive_from_master_key(master_key))
}

/// Whether the server refused a change because the group moved on meanwhile;
/// fetch it again and rebuild the change on the new revision.
pub fn is_group_change_conflict(error: &ServiceError) -> bool {
    matches!(
        error,
        ServiceError::UnhandledResponseCode { status, .. } if status.as_u16() == 409
    )
}

/// The signed change the server answered a `PATCH` with.
pub fn signed_group_change(
    response: proto::GroupChangeResponse,
) -> Result<proto::GroupChange, ServiceError> {
    response.group_change.ok_or(ServiceError::GroupsV2Error)
}

impl<C: CredentialsCache> GroupsManager<C> {
    pub fn server_public_params(&self) -> &ServerPublicParams {
        &self.server_public_params
    }

    /// `PUT /v2/groups/`: `group` as `GroupOperations::encrypt_group_with_credentials`
    /// makes it. Returns the group as stored, at revision 0.
    pub async fn create_group<R: Rng + CryptoRng>(
        &mut self,
        csprng: &mut R,
        master_key_bytes: &[u8],
        group: proto::Group,
    ) -> Result<proto::Group, ServiceError> {
        let group_secret_params = secret_params(master_key_bytes)?;
        let authorization = self
            .get_authorization_for_today(csprng, group_secret_params)
            .await?;
        self.identified_push_service
            .put_group(authorization, group)
            .await?
            .group
            .ok_or(ServiceError::GroupsV2Error)
    }

    /// `PATCH /v2/groups/`. Returns the server-signed change, to send on to the
    /// members in a `GroupContextV2`. See [`is_group_change_conflict`].
    pub async fn modify_group<R: Rng + CryptoRng>(
        &mut self,
        csprng: &mut R,
        master_key_bytes: &[u8],
        actions: proto::group_change::Actions,
    ) -> Result<proto::GroupChange, ServiceError> {
        self.patch_group(csprng, master_key_bytes, actions, None)
            .await
    }

    /// For a non-member: joining or asking to join through the link, or
    /// withdrawing that request. Returns the server-signed change.
    pub async fn modify_group_from_invite_link<R: Rng + CryptoRng>(
        &mut self,
        csprng: &mut R,
        link: &GroupInviteLink,
        actions: proto::group_change::Actions,
    ) -> Result<proto::GroupChange, ServiceError> {
        self.patch_group(
            csprng,
            &link.master_key,
            actions,
            Some(&link.password),
        )
        .await
    }

    async fn patch_group<R: Rng + CryptoRng>(
        &mut self,
        csprng: &mut R,
        master_key_bytes: &[u8],
        actions: proto::group_change::Actions,
        invite_link_password: Option<&[u8]>,
    ) -> Result<proto::GroupChange, ServiceError> {
        let group_secret_params = secret_params(master_key_bytes)?;
        let authorization = self
            .get_authorization_for_today(csprng, group_secret_params)
            .await?;
        let response = self
            .identified_push_service
            .patch_group(authorization, actions, invite_link_password)
            .await?;
        signed_group_change(response)
    }

    /// What the link's holder may see of the group before joining.
    pub async fn group_join_info<R: Rng + CryptoRng>(
        &mut self,
        csprng: &mut R,
        link: &GroupInviteLink,
    ) -> Result<GroupJoinInfo, ServiceError> {
        let group_secret_params = secret_params(&link.master_key)?;
        let authorization = self
            .get_authorization_for_today(csprng, group_secret_params)
            .await?;
        let info = self
            .identified_push_service
            .get_group_join_info(authorization, &link.password)
            .await?;
        GroupOperations::new(group_secret_params)
            .decrypt_group_join_info(info)
            .map_err(|e: GroupDecodingError| e.into())
    }

    /// Encrypts and uploads a group avatar (JPEG or PNG, as Signal's apps
    /// send); returns the key for `GroupOperations::build_modify_avatar_action`
    /// or a new group's `avatar_url`.
    pub async fn upload_avatar<R: Rng + CryptoRng>(
        &mut self,
        csprng: &mut R,
        master_key_bytes: &[u8],
        avatar: &[u8],
    ) -> Result<String, ServiceError> {
        let group_secret_params = secret_params(master_key_bytes)?;
        let ciphertext = GroupOperations::new(group_secret_params)
            .encrypt_avatar(avatar, csprng);
        let authorization = self
            .get_authorization_for_today(csprng, group_secret_params)
            .await?;
        let form = self
            .identified_push_service
            .get_group_avatar_upload_form(authorization)
            .await?;
        let key = form.key.clone();
        self.identified_push_service
            .upload_group_avatar(form, ciphertext)
            .await?;
        Ok(key)
    }
}

#[cfg(test)]
mod tests {
    use reqwest::StatusCode;

    use super::*;

    #[test]
    fn only_409_is_a_conflict() {
        let error = |code: u16| ServiceError::UnhandledResponseCode {
            status: StatusCode::from_u16(code).unwrap(),
            body: String::new(),
        };
        assert!(is_group_change_conflict(&error(409)));
        assert!(!is_group_change_conflict(&error(400)));
        assert!(!is_group_change_conflict(&ServiceError::Unauthorized));
    }

    #[test]
    fn a_change_response_without_change_is_an_error() {
        assert!(signed_group_change(proto::GroupChangeResponse::default())
            .is_err());
        let change = proto::GroupChange {
            actions: vec![1, 2],
            server_signature: vec![3],
            change_epoch: 2,
        };
        assert_eq!(
            signed_group_change(proto::GroupChangeResponse {
                group_change: Some(change.clone()),
                group_send_endorsements_response: vec![],
            })
            .unwrap(),
            change
        );
    }

    #[test]
    fn master_keys_must_be_32_bytes() {
        assert!(secret_params(&[0; 31]).is_err());
        assert!(secret_params(&[0; 32]).is_ok());
    }
}
