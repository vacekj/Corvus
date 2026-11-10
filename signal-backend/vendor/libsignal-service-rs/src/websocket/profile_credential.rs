//! Expiring profile key credentials: what adding someone to a group (or
//! oneself, when creating, joining or accepting an invitation) presents to the
//! group server. Signal-Android: `ProfileService.getProfile` with
//! `SignalServiceProfile.RequestType.PROFILE_AND_CREDENTIAL`.

use libsignal_protocol::Aci;
use rand::{CryptoRng, Rng};
use reqwest::Method;
use serde::Deserialize;
use zkgroup::{
    profiles::{
        ExpiringProfileKeyCredential, ExpiringProfileKeyCredentialResponse,
        ProfileKey, ProfileKeyCredentialRequestContext,
    },
    ServerPublicParams,
};

use crate::{
    push_service::{ServiceError, SignalServiceResponse},
    utils::serde_optional_base64,
    websocket::{self, SignalWebSocket},
};

#[derive(Deserialize)]
struct CredentialProfile {
    #[serde(default, with = "serde_optional_base64")]
    credential: Option<Vec<u8>>,
}

/// One request for `aci`'s credential, for `profile_key`.
pub struct ExpiringProfileKeyCredentialRequest {
    context: ProfileKeyCredentialRequestContext,
    path: String,
}

impl ExpiringProfileKeyCredentialRequest {
    pub fn new<R: Rng + CryptoRng>(
        csprng: &mut R,
        aci: Aci,
        profile_key: ProfileKey,
        server_public_params: &ServerPublicParams,
    ) -> Result<Self, ServiceError> {
        let context = server_public_params
            .create_profile_key_credential_request_context(
                csprng.random(),
                aci,
                profile_key,
            );
        let version =
            bincode::serialize(&profile_key.get_profile_key_version(aci))?;
        let version = std::str::from_utf8(&version)
            .expect("hex encoded profile key version");
        let request = hex::encode(zkgroup::serialize(&context.get_request()));
        let path = format!(
            "/v1/profile/{}/{}/{}?credentialType=expiringProfileKey",
            aci.service_id_string(),
            version,
            request
        );
        Ok(Self { context, path })
    }

    pub fn path(&self) -> &str {
        &self.path
    }

    /// Reads the credential from the profile JSON the server answered with.
    /// `now` is seconds since the epoch.
    pub fn receive(
        &self,
        profile_json: &[u8],
        server_public_params: &ServerPublicParams,
        now: u64,
    ) -> Result<ExpiringProfileKeyCredential, ServiceError> {
        let profile: CredentialProfile = serde_json::from_slice(profile_json)?;
        let response =
            profile.credential.ok_or(ServiceError::InvalidFrame {
                reason: "no profile key credential in the profile",
            })?;
        let response: ExpiringProfileKeyCredentialResponse =
            zkgroup::deserialize(&response)?;
        Ok(server_public_params.receive_expiring_profile_key_credential(
            &self.context,
            &response,
            // Not truncated to the day: zkgroup refuses an expiry more than
            // 7 days ahead of it.
            zkgroup::Timestamp::from_epoch_seconds(now),
        )?)
    }
}

impl SignalWebSocket<websocket::Identified> {
    /// Fails with `NotFoundError` when `profile_key` is not `aci`'s current
    /// one; Signal's apps then invite instead of adding.
    pub async fn retrieve_expiring_profile_key_credential<
        R: Rng + CryptoRng,
    >(
        &mut self,
        csprng: &mut R,
        aci: Aci,
        profile_key: ProfileKey,
        server_public_params: &ServerPublicParams,
    ) -> Result<ExpiringProfileKeyCredential, ServiceError> {
        let request = ExpiringProfileKeyCredentialRequest::new(
            csprng,
            aci,
            profile_key,
            server_public_params,
        )?;
        let body = self
            .http_request(Method::GET, request.path())?
            .send()
            .await?
            .service_error_for_status()
            .await?
            .body;
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("after 1970")
            .as_secs();
        request.receive(
            body.as_deref().unwrap_or_default(),
            server_public_params,
            now,
        )
    }
}

#[cfg(test)]
mod tests {
    use base64::prelude::*;
    use zkgroup::{ServerSecretParams, Timestamp};

    use super::*;

    const DAY: u64 = 24 * 60 * 60;

    #[test]
    fn requests_and_receives_a_credential() {
        let mut rng = rand::rng();
        let server = ServerSecretParams::generate(rng.random());
        let public = server.get_public_params();
        let aci = Aci::from_uuid_bytes([7; 16]);
        let profile_key = ProfileKey::create([9; 32]);

        let request = ExpiringProfileKeyCredentialRequest::new(
            &mut rng,
            aci,
            profile_key,
            &public,
        )
        .unwrap();
        let mut parts = request.path().split('/');
        assert_eq!(parts.nth(3), Some(aci.service_id_string().as_str()));
        let version = parts.next().unwrap();
        assert_eq!(version.len(), 64);
        assert!(version.chars().all(|c| c.is_ascii_hexdigit()));
        assert!(request.path().ends_with("?credentialType=expiringProfileKey"));

        // What the server does with the request.
        let expiration = Timestamp::from_epoch_seconds(20_000 * DAY);
        let response = server
            .issue_expiring_profile_key_credential(
                rng.random(),
                &request.context.get_request(),
                aci,
                profile_key.get_commitment(aci),
                expiration,
            )
            .unwrap();
        let json = format!(
            r#"{{"identityKey":null,"name":null,"credential":"{}","capabilities":{{}}}}"#,
            BASE64_STANDARD.encode(zkgroup::serialize(&response))
        );

        let credential = request
            .receive(json.as_bytes(), &public, 20_000 * DAY - 3 * DAY)
            .unwrap();
        assert_eq!(credential.aci(), aci);
        assert_eq!(credential.get_expiration_time(), expiration);

        // Expired by now, or a profile without one.
        assert!(request
            .receive(json.as_bytes(), &public, 20_000 * DAY)
            .is_err());
        assert!(request
            .receive(br#"{"capabilities":{}}"#, &public, 0)
            .is_err());
    }
}
