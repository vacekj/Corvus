//! Versioned profile write that also carries `phoneNumberSharing`.
//!
//! A profile write replaces every field, so a write without
//! `phoneNumberSharing` turns phone number sharing off for the account.

use aes_gcm::aead::Aead;
use aes_gcm::{Aes256Gcm, KeyInit};
use libsignal_core::Aci;
use rand::{CryptoRng, Rng};
use reqwest::Method;
use serde::Serialize;
use zkgroup::profiles::ProfileKey;

use crate::profile_cipher::ProfileCipher;
use crate::profile_name::ProfileName;
use crate::push_service::response::SignalServiceResponse;
use crate::utils::serde_base64;
use crate::ProfileManagerError;

use super::{Identified, SignalWebSocket};

const NONCE_LEN: usize = 12;

/// Profile fields to write. `None` about/emoji are written as empty.
#[derive(Debug, Clone)]
pub struct ProfileFields<'a> {
    pub name: ProfileName<&'a str>,
    pub about: Option<&'a str>,
    pub about_emoji: Option<&'a str>,
    /// Keep the current avatar (`sameAvatar`); otherwise the avatar is removed.
    pub retain_avatar: bool,
    /// Whether profile readers may see the phone number. `None` omits the
    /// field, which the server stores as "not shared".
    pub phone_number_sharing: Option<bool>,
}

/// `phoneNumberSharing` ciphertext: one byte (1 = shared), AES-256-GCM with
/// the profile key, `nonce(12) || ciphertext+tag`.
pub fn encrypt_phone_number_sharing<R: Rng + CryptoRng>(
    profile_key: &ProfileKey,
    sharing: bool,
    rng: &mut R,
) -> Vec<u8> {
    let nonce: [u8; NONCE_LEN] = rng.random();
    let cipher = Aes256Gcm::new(&profile_key.get_bytes().into());
    let ciphertext = cipher
        .encrypt(&nonce.into(), &[u8::from(sharing)][..])
        .expect("AES-GCM encryption of one byte");
    let mut out = nonce.to_vec();
    out.extend(ciphertext);
    out
}

/// Inverse of [`encrypt_phone_number_sharing`]; `None` if undecryptable.
pub fn decrypt_phone_number_sharing(
    profile_key: &ProfileKey,
    bytes: &[u8],
) -> Option<bool> {
    let (nonce, ciphertext) = bytes.split_first_chunk::<NONCE_LEN>()?;
    let plaintext = Aes256Gcm::new(&profile_key.get_bytes().into())
        .decrypt(nonce.into(), ciphertext)
        .ok()?;
    Some(plaintext.first() == Some(&1))
}

impl SignalWebSocket<Identified> {
    /// `PUT /v1/profile` with the given fields (no new avatar upload).
    pub async fn write_profile_fields(
        &mut self,
        aci: Aci,
        profile_key: ProfileKey,
        fields: ProfileFields<'_>,
    ) -> Result<(), ProfileManagerError> {
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct Request {
            version: String,
            #[serde(with = "serde_base64")]
            name: Vec<u8>,
            #[serde(with = "serde_base64")]
            about: Vec<u8>,
            #[serde(with = "serde_base64")]
            about_emoji: Vec<u8>,
            avatar: bool,
            same_avatar: bool,
            #[serde(with = "serde_base64")]
            commitment: Vec<u8>,
            #[serde(
                skip_serializing_if = "Option::is_none",
                with = "crate::utils::serde_optional_base64"
            )]
            phone_number_sharing: Option<Vec<u8>>,
        }

        let cipher = ProfileCipher::new(profile_key);
        let version = bincode::serialize(&profile_key.get_profile_key_version(aci))
            .map_err(crate::push_service::ServiceError::from)?;
        let commitment = bincode::serialize(&profile_key.get_commitment(aci))
            .map_err(crate::push_service::ServiceError::from)?;
        // The thread-local RNG must not live across the await below.
        let request = {
            let rng = &mut rand::rng();
            Request {
                version: String::from_utf8(version)
                    .expect("profile key version is hex encoded"),
                name: cipher.encrypt_name(&fields.name, rng)?,
                about: cipher.encrypt_about(
                    fields.about.unwrap_or_default().into(),
                    rng,
                )?,
                about_emoji: cipher.encrypt_emoji(
                    fields.about_emoji.unwrap_or_default().into(),
                    rng,
                )?,
                avatar: fields.retain_avatar,
                same_avatar: fields.retain_avatar,
                commitment,
                phone_number_sharing: fields.phone_number_sharing.map(
                    |sharing| {
                        encrypt_phone_number_sharing(&profile_key, sharing, rng)
                    },
                ),
            }
        };

        self.http_request(Method::PUT, "/v1/profile")?
            .send_json(&request)
            .await?
            .service_error_for_status()
            .await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn phone_number_sharing_round_trip() {
        let mut rng = rand::rng();
        let key = ProfileKey::generate(rng.random());
        for sharing in [true, false] {
            let ciphertext =
                encrypt_phone_number_sharing(&key, sharing, &mut rng);
            // nonce + 1 byte + 16 byte tag
            assert_eq!(ciphertext.len(), 12 + 1 + 16);
            assert_eq!(
                decrypt_phone_number_sharing(&key, &ciphertext),
                Some(sharing)
            );
        }
        let other = ProfileKey::generate(rng.random());
        let ciphertext = encrypt_phone_number_sharing(&key, true, &mut rng);
        assert_eq!(decrypt_phone_number_sharing(&other, &ciphertext), None);
    }
}
