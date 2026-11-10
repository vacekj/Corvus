//! Setting, confirming and deleting the account's username and username link.
//!
//! Signal-Server: `controllers/AccountController.java`
//! (`/v1/accounts/username_hash/{reserve,confirm}`, `/v1/accounts/username_link`).

use base64::prelude::BASE64_URL_SAFE_NO_PAD;
use base64::Engine;
use rand::Rng;
use reqwest::{Method, StatusCode};
use serde::{Deserialize, Serialize};
use usernames::constants::USERNAME_LINK_ENTROPY_SIZE;
use usernames::{NicknameLimits, Username, UsernameError, UsernameLinkError};
use uuid::Uuid;

use crate::content::ServiceError;
use crate::push_service::response::SignalServiceResponse;
use crate::utils::{
    serde_base64_url_safe_no_pad, serde_optional_base64_url_safe_no_pad,
};

use super::{Identified, SignalWebSocket};

pub use super::usernames::generate_username_link;

/// The server accepts at most this many hashes per reservation.
pub const MAX_USERNAME_CANDIDATES: usize = 20;

#[derive(Debug, thiserror::Error)]
pub enum UsernameManagementError {
    /// Every candidate hash is taken (reserve returned 409).
    #[error("username is taken")]
    Taken,
    /// No matching reservation, e.g. it expired (confirm returned 409).
    #[error("username reservation not found")]
    ReservationNotFound,
    /// The reserved username can no longer be used (confirm returned 410).
    #[error("username is no longer available")]
    Unavailable,
    /// The server rejected the request format or proof (422).
    #[error("username request rejected as invalid")]
    Rejected,
    #[error("invalid username: {0}")]
    InvalidUsername(#[from] UsernameError),
    #[error("username link: {0}")]
    Link(#[from] UsernameLinkError),
    #[error(transparent)]
    Service(#[from] ServiceError),
}

/// A username confirmed for this account, with the username link that was
/// set up alongside it.
#[derive(Debug)]
pub struct ConfirmedUsername {
    pub username: Username,
    pub link_entropy: [u8; USERNAME_LINK_ENTROPY_SIZE],
    pub link_handle: Uuid,
}

impl ConfirmedUsername {
    /// `https://signal.me/#eu/...`
    pub fn link(&self) -> url::Url {
        generate_username_link(self.link_handle, &self.link_entropy)
    }
}

/// Usernames to try for `requested`: the username itself when it carries a
/// discriminator (`name.42`), otherwise `requested` as a nickname with random
/// discriminators.
pub fn username_candidates<R: Rng>(
    rng: &mut R,
    requested: &str,
) -> Result<Vec<Username>, UsernameError> {
    if requested.contains('.') {
        return Ok(vec![Username::new(requested)?]);
    }
    let mut candidates: Vec<Username> =
        Username::candidates_from(rng, requested, NicknameLimits::default())?
            .iter()
            .map(|c| Username::new(c))
            .collect::<Result<_, _>>()?;
    candidates.truncate(MAX_USERNAME_CANDIDATES);
    Ok(candidates)
}

impl SignalWebSocket<Identified> {
    /// Reserves the first free hash out of `hashes` and returns it.
    pub async fn reserve_username_hash(
        &mut self,
        hashes: &[[u8; 32]],
    ) -> Result<[u8; 32], UsernameManagementError> {
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct Request<'a> {
            username_hashes: Vec<UrlSafe<'a>>,
        }
        #[derive(Serialize)]
        struct UrlSafe<'a>(
            #[serde(with = "serde_base64_url_safe_no_pad")] &'a [u8; 32],
        );
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Response {
            #[serde(with = "serde_base64_url_safe_no_pad")]
            username_hash: Vec<u8>,
        }

        let response = self
            .http_request(Method::PUT, "/v1/accounts/username_hash/reserve")?
            .send_json(Request {
                username_hashes: hashes.iter().map(UrlSafe).collect(),
            })
            .await?;
        match response.status_code() {
            Some(StatusCode::CONFLICT) => {
                return Err(UsernameManagementError::Taken)
            },
            Some(StatusCode::UNPROCESSABLE_ENTITY) => {
                return Err(UsernameManagementError::Rejected)
            },
            _ => {},
        }
        let response: Response =
            response.service_error_for_status().await?.json().await?;
        response.username_hash.try_into().map_err(|_| {
            ServiceError::InvalidFrame {
                reason: "reserved username hash has the wrong length",
            }
            .into()
        })
    }

    /// Confirms a reserved hash with its zero-knowledge proof. With
    /// `encrypted_username` (see [`usernames::create_for_username`]) the
    /// server also sets the username link and returns its handle.
    pub async fn confirm_username_hash(
        &mut self,
        hash: &[u8; 32],
        proof: &[u8],
        encrypted_username: Option<&[u8]>,
    ) -> Result<Option<Uuid>, UsernameManagementError> {
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct Request<'a> {
            #[serde(with = "serde_base64_url_safe_no_pad")]
            username_hash: &'a [u8; 32],
            #[serde(with = "serde_base64_url_safe_no_pad")]
            zk_proof: &'a [u8],
            #[serde(
                with = "serde_optional_base64_url_safe_no_pad",
                skip_serializing_if = "Option::is_none"
            )]
            encrypted_username: Option<&'a [u8]>,
        }
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Response {
            #[serde(default)]
            username_link_handle: Option<Uuid>,
        }

        let response = self
            .http_request(Method::PUT, "/v1/accounts/username_hash/confirm")?
            .send_json(Request {
                username_hash: hash,
                zk_proof: proof,
                encrypted_username,
            })
            .await?;
        match response.status_code() {
            Some(StatusCode::CONFLICT) => {
                return Err(UsernameManagementError::ReservationNotFound)
            },
            Some(StatusCode::GONE) => {
                return Err(UsernameManagementError::Unavailable)
            },
            Some(StatusCode::UNPROCESSABLE_ENTITY) => {
                return Err(UsernameManagementError::Rejected)
            },
            _ => {},
        }
        let response: Response =
            response.service_error_for_status().await?.json().await?;
        Ok(response.username_link_handle)
    }

    /// Reserves and confirms a username (see [`username_candidates`]) and sets
    /// its username link.
    pub async fn set_username(
        &mut self,
        requested: &str,
    ) -> Result<ConfirmedUsername, UsernameManagementError> {
        let candidates = username_candidates(&mut rand::rng(), requested)?;
        let hashes: Vec<[u8; 32]> =
            candidates.iter().map(Username::hash).collect();
        let reserved = self.reserve_username_hash(&hashes).await?;
        let username = candidates
            .into_iter()
            .find(|c| c.hash() == reserved)
            .ok_or(ServiceError::InvalidFrame {
                reason: "server reserved a username hash we did not offer",
            })?;

        let randomness: [u8; 32] = rand::rng().random();
        let proof = username.proof(&randomness)?;
        let (link_entropy, encrypted_username) =
            usernames::create_for_username(
                &mut rand::rng(),
                username.to_string(),
                None,
            )?;

        let handle = self
            .confirm_username_hash(
                &reserved,
                &proof,
                Some(&encrypted_username),
            )
            .await?;
        let link_handle = match handle {
            Some(handle) => handle,
            // Older servers don't set the link while confirming.
            None => {
                return Ok(self
                    .set_username_link_parts(&username, false)
                    .await
                    .map(|(link_entropy, link_handle)| ConfirmedUsername {
                        username,
                        link_entropy,
                        link_handle,
                    })?)
            },
        };
        Ok(ConfirmedUsername {
            username,
            link_entropy,
            link_handle,
        })
    }

    /// Deletes the account's username (and with it the username link).
    pub async fn delete_username_hash(&mut self) -> Result<(), ServiceError> {
        self.http_request(Method::DELETE, "/v1/accounts/username_hash")?
            .send()
            .await?
            .service_error_for_status()
            .await?;
        Ok(())
    }

    /// Like [`Self::set_username_link`], but returns the link entropy and the
    /// server-assigned handle, which belong in the `AccountRecord`.
    pub async fn set_username_link_parts(
        &mut self,
        username: &Username,
        keep_link_handle: bool,
    ) -> Result<([u8; USERNAME_LINK_ENTROPY_SIZE], Uuid), UsernameManagementError>
    {
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct Request {
            #[serde(with = "serde_base64_url_safe_no_pad")]
            username_link_encrypted_value: Vec<u8>,
            keep_link_handle: bool,
        }
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Response {
            username_link_handle: Uuid,
        }

        let (entropy, ciphertext) = usernames::create_for_username(
            &mut rand::rng(),
            username.to_string(),
            None,
        )?;
        let response = self
            .http_request(Method::PUT, "/v1/accounts/username_link")?
            .send_json(Request {
                username_link_encrypted_value: ciphertext,
                keep_link_handle,
            })
            .await?;
        if response.status_code() == Some(StatusCode::CONFLICT) {
            return Err(ServiceError::UsernameHashNotSet.into());
        }
        let response: Response =
            response.service_error_for_status().await?.json().await?;
        Ok((entropy, response.username_link_handle))
    }

    /// Deletes the username link; the username itself stays.
    pub async fn delete_username_link(&mut self) -> Result<(), ServiceError> {
        self.http_request(Method::DELETE, "/v1/accounts/username_link")?
            .send()
            .await?
            .service_error_for_status()
            .await?;
        Ok(())
    }
}

/// `https://signal.me/#eu/...` payload: URL-safe base64 of entropy || handle.
pub fn username_link_payload(
    entropy: &[u8; USERNAME_LINK_ENTROPY_SIZE],
    handle: Uuid,
) -> String {
    let mut payload = entropy.to_vec();
    payload.extend_from_slice(handle.as_bytes());
    BASE64_URL_SAFE_NO_PAD.encode(payload)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn candidates_for_nickname_and_full_username() {
        let mut rng = rand::rng();
        let candidates = username_candidates(&mut rng, "corvus").unwrap();
        assert_eq!(candidates.len(), MAX_USERNAME_CANDIDATES);
        for candidate in &candidates {
            let text = candidate.to_string();
            let (nickname, discriminator) = text.rsplit_once('.').unwrap();
            assert_eq!(nickname, "corvus");
            assert!(discriminator.len() >= 2);
        }

        let exact = username_candidates(&mut rng, "corvus.42").unwrap();
        assert_eq!(exact.len(), 1);
        assert_eq!(exact[0].to_string(), "corvus.42");

        assert!(username_candidates(&mut rng, "0corvus").is_err());
        assert!(username_candidates(&mut rng, "corvus.00").is_err());
        assert!(username_candidates(&mut rng, "co").is_err());
    }

    #[test]
    fn hash_is_case_insensitive_and_proof_verifies() {
        let a = Username::new("Corvus.42").unwrap();
        let b = Username::new("corvus.42").unwrap();
        assert_eq!(a.hash(), b.hash());
        assert_ne!(a.hash(), Username::new("corvus.43").unwrap().hash());

        let proof = a.proof(&[7; 32]).unwrap();
        Username::verify_proof(&proof, a.hash()).unwrap();
        assert!(Username::verify_proof(
            &proof,
            Username::new("corvus.43").unwrap().hash()
        )
        .is_err());
    }

    /// Vector from libsignal `rust/net/chat/src/ws/usernames.rs`.
    #[test]
    fn decrypts_known_username_link_ciphertext() {
        let entropy: [u8; 32] = hex::decode(
            "4302c613c092a51c5394becffeb6f697300a605348e93f03c3db95e0b03d28f1",
        )
        .unwrap()
        .try_into()
        .unwrap();
        let ciphertext = BASE64_URL_SAFE_NO_PAD
            .decode("kj5ah-VbEgjpfJsNt-Wto2H626DRmJSVpYPy0yPOXA8kiSFkBCD8ysFlJ-Z3MhiAnt_R3Nm7ZY0W5fiRDLVbhaE2z-KO2xdf5NcVbkewCzhvveecS3hHskDp1aSfbvwTZNNGPmAuKWvJ1MPdHzsF0w")
            .unwrap();
        assert_eq!(
            usernames::decrypt_username(&entropy, &ciphertext).unwrap(),
            "moxie.01"
        );
    }

    #[test]
    fn link_encoding() {
        let entropy = [0x42; 32];
        let handle = uuid::uuid!("9d0652a3-dcc3-4d11-975f-74d61598733f");
        let confirmed = ConfirmedUsername {
            username: Username::new("corvus.42").unwrap(),
            link_entropy: entropy,
            link_handle: handle,
        };
        let payload = username_link_payload(&entropy, handle);
        assert_eq!(
            confirmed.link().as_str(),
            format!("https://signal.me/#eu/{payload}")
        );
        let decoded = BASE64_URL_SAFE_NO_PAD.decode(&payload).unwrap();
        assert_eq!(&decoded[..32], &entropy);
        assert_eq!(&decoded[32..], handle.as_bytes());

        // A link built from our entropy decrypts what we would upload.
        let (_, ciphertext) = usernames::create_for_username(
            &mut rand::rng(),
            "corvus.42".into(),
            Some(&entropy),
        )
        .unwrap();
        assert_eq!(
            usernames::decrypt_username(&entropy, &ciphertext).unwrap(),
            "corvus.42"
        );
    }
}
