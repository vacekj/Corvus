use libsignal_service::{
    groups_v2::{AccessRequired, GroupInviteLink, Role},
    prelude::{ProfileKey, Timer, Uuid},
    protocol::{Aci, Pni, ServiceId},
};
use serde::{Deserialize, Serialize};

use super::ServiceIdType;
use libsignal_service::utils::serde_aci;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AccessControl {
    pub attributes: AccessRequired,
    pub members: AccessRequired,
    pub add_from_invite_link: AccessRequired,
    #[serde(default = "default_access_required")]
    pub member_label: AccessRequired,
}

/// According to https://github.com/signalapp/Signal-Desktop/blob/9c246150585a65b6c3be324e2c214cb4f62c6102/ts/groups.preload.ts#L503.
fn default_access_required() -> AccessRequired {
    AccessRequired::Member
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Group {
    pub title: String,
    pub avatar: String,
    pub disappearing_messages_timer: Option<Timer>,
    pub access_control: Option<AccessControl>,
    pub revision: u32,
    pub members: Vec<Member>,
    pub pending_members: Vec<PendingMember>,
    pub requesting_members: Vec<RequestingMember>,
    pub invite_link_password: Vec<u8>,
    pub description: Option<String>,
    /// Only administrators may send messages.
    #[serde(default)]
    pub announcements_only: bool,
    #[serde(default)]
    pub banned_members: Vec<BannedMember>,
    /// Ended by an administrator; nothing can change any more.
    #[serde(default)]
    pub terminated: bool,
}

impl Group {
    /// Whether `aci` is a full member (not only invited or requesting to join).
    pub fn is_member(&self, aci: &Aci) -> bool {
        self.members.iter().any(|member| member.aci == *aci)
    }

    pub fn is_admin(&self, aci: &Aci) -> bool {
        self.members
            .iter()
            .any(|member| member.aci == *aci && member.role == Role::Administrator)
    }

    /// The group's invite link, if it is turned on.
    pub fn invite_link(&self, master_key: [u8; 32]) -> Option<GroupInviteLink> {
        let open = matches!(
            self.access_control.as_ref()?.add_from_invite_link,
            AccessRequired::Any | AccessRequired::Administrator
        );
        (open && !self.invite_link_password.is_empty()).then(|| GroupInviteLink {
            master_key,
            password: self.invite_link_password.clone(),
        })
    }
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Member {
    #[serde(alias = "uuid", with = "serde_aci")]
    pub aci: Aci,
    pub role: Role,
    pub profile_key: ProfileKey,
    pub joined_at_revision: u32,
    pub label: Option<String>,
    pub label_emoji: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
pub struct PendingMember {
    // for backwards compatibility
    pub uuid: Uuid,
    #[serde(default)]
    pub service_id_type: ServiceIdType,
    pub role: Role,
    #[serde(alias = "added_by_uuid", with = "serde_aci")]
    pub added_by_aci: Aci,
    pub timestamp: u64,
}

impl PendingMember {
    /// Who is invited: an ACI, or a PNI when invited by phone number.
    pub fn service_id(&self) -> ServiceId {
        service_id(self.uuid, &self.service_id_type)
    }
}

/// Someone who may not join, ask to join or be invited.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
pub struct BannedMember {
    pub uuid: Uuid,
    #[serde(default)]
    pub service_id_type: ServiceIdType,
    /// When they were banned, in milliseconds since the epoch.
    pub timestamp: u64,
}

impl BannedMember {
    pub fn service_id(&self) -> ServiceId {
        service_id(self.uuid, &self.service_id_type)
    }
}

fn service_id(uuid: Uuid, kind: &ServiceIdType) -> ServiceId {
    match kind {
        ServiceIdType::AccountIdentity => Aci::from(uuid).into(),
        ServiceIdType::PhoneNumberIdentity => Pni::from(uuid).into(),
    }
}

#[derive(derive_more::Debug, Clone, Deserialize, Serialize)]
pub struct RequestingMember {
    #[serde(alias = "uuid", with = "serde_aci")]
    pub aci: Aci,
    #[debug(ignore)]
    pub profile_key: ProfileKey,
    pub timestamp: u64,
}

impl From<libsignal_service::groups_v2::Group> for Group {
    fn from(val: libsignal_service::groups_v2::Group) -> Self {
        Group {
            title: val.title,
            avatar: val.avatar,
            disappearing_messages_timer: val.disappearing_messages_timer,
            access_control: val.access_control.map(Into::into),
            revision: val.version,
            members: val.members.into_iter().map(Into::into).collect(),
            pending_members: val
                .members_pending_profile_key
                .into_iter()
                .map(Into::into)
                .collect(),
            requesting_members: val
                .members_pending_admin_approval
                .into_iter()
                .map(Into::into)
                .collect(),
            invite_link_password: val.invite_link_password,
            description: val.description_text,
            announcements_only: val.announcements_only,
            banned_members: val.members_banned.into_iter().map(Into::into).collect(),
            terminated: val.terminated,
        }
    }
}

impl From<libsignal_service::groups_v2::BannedMember> for BannedMember {
    fn from(val: libsignal_service::groups_v2::BannedMember) -> Self {
        BannedMember {
            uuid: val.user_id.raw_uuid(),
            service_id_type: val.user_id.kind().into(),
            timestamp: val.timestamp,
        }
    }
}

impl From<libsignal_service::groups_v2::Member> for Member {
    fn from(val: libsignal_service::groups_v2::Member) -> Self {
        Member {
            aci: val.aci,
            role: val.role,
            profile_key: val.profile_key,
            joined_at_revision: val.joined_at_version,
            label: val.label,
            label_emoji: val.label_emoji,
        }
    }
}

impl From<libsignal_service::groups_v2::PendingMember> for PendingMember {
    fn from(val: libsignal_service::groups_v2::PendingMember) -> Self {
        PendingMember {
            uuid: val.address.raw_uuid(),
            service_id_type: val.address.kind().into(),
            role: val.role,
            added_by_aci: val.added_by_aci,
            timestamp: val.timestamp,
        }
    }
}

impl From<libsignal_service::groups_v2::RequestingMember> for RequestingMember {
    fn from(val: libsignal_service::groups_v2::RequestingMember) -> Self {
        RequestingMember {
            aci: val.aci,
            profile_key: val.profile_key,
            timestamp: val.timestamp,
        }
    }
}

impl From<libsignal_service::groups_v2::AccessControl> for AccessControl {
    fn from(val: libsignal_service::groups_v2::AccessControl) -> Self {
        Self {
            attributes: val.attributes,
            members: val.members,
            add_from_invite_link: val.add_from_invite_link,
            member_label: val.member_label,
        }
    }
}
