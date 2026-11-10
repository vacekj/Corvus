//! Group server write endpoints, as Signal-Android's `PushServiceSocket` calls
//! them (`GROUPSV2_GROUP`, `GROUPSV2_GROUP_PASSWORD`, `GROUPSV2_GROUP_JOIN`,
//! `GROUPSV2_AVATAR_REQUEST`).

use base64::prelude::*;
use reqwest::{multipart::Part, Method};

use super::{
    protobuf::{ProtobufRequestBuilderExt, ProtobufResponseExt},
    HttpAuth, HttpAuthOverride, PushService, ServiceError,
    SignalServiceResponse,
};
use crate::{configuration::Endpoint, proto};

/// Path of a group change; the invite link password lets a non-member join,
/// ask to join or withdraw that request.
pub(crate) fn patch_group_path(invite_link_password: Option<&[u8]>) -> String {
    match invite_link_password {
        Some(password) => format!(
            "/v2/groups/?inviteLinkPassword={}",
            BASE64_URL_SAFE_NO_PAD.encode(password)
        ),
        None => "/v2/groups/".into(),
    }
}

pub(crate) fn group_join_info_path(invite_link_password: &[u8]) -> String {
    format!(
        "/v1/groups/join/{}",
        BASE64_URL_SAFE_NO_PAD.encode(invite_link_password)
    )
}

impl PushService {
    /// `PUT /v2/groups/`. Under `/v1` the server answers with an empty body.
    pub(crate) async fn put_group(
        &mut self,
        credentials: HttpAuth,
        group: proto::Group,
    ) -> Result<proto::GroupResponse, ServiceError> {
        self.request(
            Method::PUT,
            Endpoint::storage("/v2/groups/"),
            HttpAuthOverride::Identified(credentials),
        )?
        .protobuf(group)
        .map_err(|_| ServiceError::GroupsV2Error)?
        .send()
        .await?
        .service_error_for_status()
        .await?
        .protobuf()
        .await
    }

    /// `PATCH /v2/groups/`. A 409 means the group moved past
    /// `actions.version - 1`: fetch it again and rebuild the change.
    pub(crate) async fn patch_group(
        &mut self,
        credentials: HttpAuth,
        actions: proto::group_change::Actions,
        invite_link_password: Option<&[u8]>,
    ) -> Result<proto::GroupChangeResponse, ServiceError> {
        self.request(
            Method::PATCH,
            Endpoint::storage(patch_group_path(invite_link_password)),
            HttpAuthOverride::Identified(credentials),
        )?
        .protobuf(actions)
        .map_err(|_| ServiceError::GroupsV2Error)?
        .send()
        .await?
        .service_error_for_status()
        .await?
        .protobuf()
        .await
    }

    pub(crate) async fn get_group_join_info(
        &mut self,
        credentials: HttpAuth,
        invite_link_password: &[u8],
    ) -> Result<proto::GroupJoinInfo, ServiceError> {
        self.request(
            Method::GET,
            Endpoint::storage(group_join_info_path(invite_link_password)),
            HttpAuthOverride::Identified(credentials),
        )?
        .send()
        .await?
        .service_error_for_status()
        .await?
        .protobuf()
        .await
    }

    pub(crate) async fn get_group_avatar_upload_form(
        &mut self,
        credentials: HttpAuth,
    ) -> Result<proto::AvatarUploadAttributes, ServiceError> {
        self.request(
            Method::GET,
            Endpoint::storage("/v1/groups/avatar/form"),
            HttpAuthOverride::Identified(credentials),
        )?
        .send()
        .await?
        .service_error_for_status()
        .await?
        .protobuf()
        .await
    }

    /// Posts the encrypted avatar to the root of CDN 0, where the form's key
    /// names it. Unlike `upload_to_cdn0`, sends no account credentials.
    pub(crate) async fn upload_group_avatar(
        &mut self,
        form: proto::AvatarUploadAttributes,
        ciphertext: Vec<u8>,
    ) -> Result<(), ServiceError> {
        // S3 wants the fields in this order.
        let form_data = reqwest::multipart::Form::new()
            .text("acl", form.acl)
            .text("key", form.key)
            .text("policy", form.policy)
            .text("Content-Type", "application/octet-stream")
            .text("x-amz-algorithm", form.algorithm)
            .text("x-amz-credential", form.credential)
            .text("x-amz-date", form.date)
            .text("x-amz-signature", form.signature)
            .part(
                "file",
                Part::bytes(ciphertext)
                    .mime_str("application/octet-stream")?
                    .file_name("file"),
            );
        self.request(
            Method::POST,
            Endpoint::cdn(0, ""),
            HttpAuthOverride::Unidentified,
        )?
        .multipart(form_data)
        .send()
        .await?
        .error_for_status()?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use prost::Message;

    use super::*;

    #[test]
    fn invite_link_password_goes_url_safe_without_padding() {
        let password = [0xfb, 0xff, 0xfe, 0x00, 0x01];
        assert_eq!(patch_group_path(None), "/v2/groups/");
        assert_eq!(
            patch_group_path(Some(&password)),
            "/v2/groups/?inviteLinkPassword=-__-AAE"
        );
        assert_eq!(group_join_info_path(&password), "/v1/groups/join/-__-AAE");
    }

    #[test]
    fn parses_group_change_response() {
        let change = proto::GroupChange {
            actions: proto::group_change::Actions {
                version: 4,
                ..Default::default()
            }
            .encode_to_vec(),
            server_signature: vec![1; 64],
            change_epoch: 6,
        };
        let body = proto::GroupChangeResponse {
            group_change: Some(change.clone()),
            group_send_endorsements_response: vec![9; 3],
        }
        .encode_to_vec();
        let response =
            proto::GroupChangeResponse::decode(body.as_slice()).unwrap();
        assert_eq!(response.group_change, Some(change));
    }

    #[test]
    fn parses_avatar_upload_form() {
        let form = proto::AvatarUploadAttributes {
            key: "groups/abc".into(),
            credential: "cred".into(),
            acl: "private".into(),
            algorithm: "AWS4-HMAC-SHA256".into(),
            date: "20261109T000000Z".into(),
            policy: "policy".into(),
            signature: "sig".into(),
        };
        let decoded = proto::AvatarUploadAttributes::decode(
            form.encode_to_vec().as_slice(),
        )
        .unwrap();
        assert_eq!(decoded, form);
    }
}
