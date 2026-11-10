//! Adapted from whisperfish/libsignal-service-rs#473 (Rafael Bachmann).

use base64::prelude::*;
use prost::Message;

use crate::proto;

use super::AccessRequired;

/// What a `https://signal.group/#…` link carries. Whoever has the link can join the
/// group, or ask to, as its invite-link access allows.
#[derive(Clone, PartialEq, Eq, derive_more::Debug)]
pub struct GroupInviteLink {
    #[debug(ignore)]
    pub master_key: [u8; 32],
    #[debug(ignore)]
    pub password: Vec<u8>,
}

impl GroupInviteLink {
    pub const PREFIX: &'static str = "https://signal.group/#";

    /// As Signal-Android's `GroupLinkPassword.createNew()`.
    pub fn new_password<R: rand::Rng + rand::CryptoRng>(
        rng: &mut R,
    ) -> Vec<u8> {
        let mut password = vec![0; 16];
        rng.fill_bytes(&mut password);
        password
    }

    /// Accepts the `https://` and `sgnl://` forms.
    pub fn parse(url: &str) -> Option<Self> {
        let url = url.trim();
        let encoded = url
            .strip_prefix(Self::PREFIX)
            .or_else(|| url.strip_prefix("sgnl://signal.group/#"))?
            .trim_end_matches('=');
        let bytes = BASE64_URL_SAFE_NO_PAD.decode(encoded).ok()?;
        let link = proto::GroupInviteLink::decode(bytes.as_slice()).ok()?;
        let proto::group_invite_link::Contents::ContentsV1(contents) =
            link.contents?;
        Some(Self {
            master_key: contents.group_master_key.try_into().ok()?,
            password: contents.invite_link_password,
        })
    }

    pub fn to_url(&self) -> String {
        let link = proto::GroupInviteLink {
            contents: Some(proto::group_invite_link::Contents::ContentsV1(
                proto::group_invite_link::GroupInviteLinkContentsV1 {
                    group_master_key: self.master_key.to_vec(),
                    invite_link_password: self.password.clone(),
                },
            )),
        };
        format!(
            "{}{}",
            Self::PREFIX,
            BASE64_URL_SAFE_NO_PAD.encode(link.encode_to_vec())
        )
    }
}

/// What a group shows to someone holding its invite link.
#[derive(Debug, Clone, PartialEq)]
pub struct GroupJoinInfo {
    pub title: String,
    pub description_text: Option<String>,
    /// CDN key of the encrypted avatar; empty when there is none.
    pub avatar: String,
    pub member_count: u32,
    /// `Any` lets the holder join, `Administrator` makes them ask first.
    pub add_from_invite_link: AccessRequired,
    pub revision: u32,
    /// The caller has asked to join and awaits an administrator.
    pub pending_admin_approval: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip() {
        let link = GroupInviteLink {
            master_key: [7; 32],
            password: GroupInviteLink::new_password(&mut rand::rng()),
        };
        let url = link.to_url();
        assert!(url.starts_with("https://signal.group/#"));
        assert_eq!(GroupInviteLink::parse(&url), Some(link.clone()));
        let sgnl = url.replacen("https://", "sgnl://", 1);
        assert_eq!(GroupInviteLink::parse(&sgnl), Some(link));
        assert_eq!(GroupInviteLink::parse("https://signal.org/#abc"), None);
        assert_eq!(GroupInviteLink::parse("https://signal.group/#!!"), None);
    }

    #[test]
    fn parses_a_link_made_by_signal_android() {
        // GroupInviteLink { contentsV1 { masterKey = 0x01..0x20, password = 0xaa * 16 } }
        let mut bytes = vec![0x0a, 0x34, 0x0a, 0x20];
        bytes.extend(1..=32u8);
        bytes.extend([0x12, 0x10]);
        bytes.extend([0xaa; 16]);
        let url = format!(
            "https://signal.group/#{}",
            BASE64_URL_SAFE_NO_PAD.encode(&bytes)
        );
        let link = GroupInviteLink::parse(&url).unwrap();
        assert_eq!(link.master_key.to_vec(), (1..=32u8).collect::<Vec<_>>());
        assert_eq!(link.password, vec![0xaa; 16]);
        assert_eq!(link.to_url(), url);
    }
}
