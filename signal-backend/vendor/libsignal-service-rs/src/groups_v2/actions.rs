//! Building the actions of a group change (`GroupChange.Actions`), as
//! Signal-Android's `GroupsV2Operations.GroupOperations` does. Each builder
//! makes one action; put them in one `Actions` with `version` set to the
//! group's revision plus one.
//!
//! Partly adapted from whisperfish/libsignal-service-rs#473 (Rafael Bachmann).

use bytes::Bytes;
use libsignal_protocol::{Aci, ServiceId};
use prost::Message;
use zkgroup::{profiles::ExpiringProfileKeyCredential, ServerPublicParams};

use crate::proto::{
    self,
    group_attribute_blob::Content,
    group_change::actions::{
        AddMemberAction, AddMemberBannedAction,
        AddMemberPendingAdminApprovalAction,
        DeleteMemberBannedAction, DeleteMemberPendingAdminApprovalAction,
        ModifyAddFromInviteLinkAccessControlAction,
        ModifyAnnouncementsOnlyAction, ModifyAttributesAccessControlAction,
        ModifyAvatarAction, ModifyDescriptionAction,
        ModifyDisappearingMessageTimerAction, ModifyInviteLinkPasswordAction,
        ModifyMemberLabelAccessControlAction, ModifyMemberLabelAction,
        ModifyMemberRoleAction, ModifyMembersAccessControlAction,
        ModifyTitleAction, PromoteMemberPendingAdminApprovalAction,
        PromoteMemberPendingPniAciProfileKeyAction,
        PromoteMemberPendingProfileKeyAction,
    },
    GroupAttributeBlob,
};

use super::{
    invite_link::GroupJoinInfo, model::Timer, AccessRequired,
    GroupDecodingError, GroupOperations, Role,
};

impl GroupOperations {
    fn ciphertext_of(&self, service_id: ServiceId) -> Vec<u8> {
        zkgroup::serialize(
            &self.group_secret_params.encrypt_service_id(service_id),
        )
    }

    fn blob<R: rand::Rng + rand::CryptoRng>(
        &self,
        plaintext: &[u8],
        rng: &mut R,
    ) -> Vec<u8> {
        self.group_secret_params.encrypt_blob_with_padding(
            rng.random(),
            plaintext,
            0,
        )
    }

    fn attribute(&self, ciphertext: &[u8]) -> Option<Content> {
        if ciphertext.is_empty() {
            return None;
        }
        let plaintext = self
            .group_secret_params
            .decrypt_blob_with_padding(ciphertext)
            .ok()?;
        GroupAttributeBlob::decode(Bytes::from(plaintext))
            .ok()?
            .content
    }

    /// The avatar as the group server's CDN keeps it.
    pub fn encrypt_avatar<R: rand::Rng + rand::CryptoRng>(
        &self,
        avatar: &[u8],
        rng: &mut R,
    ) -> Vec<u8> {
        let blob = GroupAttributeBlob {
            content: Some(Content::Avatar(avatar.to_vec())),
        };
        self.blob(&blob.encode_to_vec(), rng)
    }

    pub fn decrypt_group_join_info(
        &self,
        info: proto::GroupJoinInfo,
    ) -> Result<GroupJoinInfo, GroupDecodingError> {
        let title = match self.attribute(&info.title) {
            Some(Content::Title(title)) => title,
            _ => String::new(),
        };
        let description_text = match self.attribute(&info.description) {
            Some(Content::DescriptionText(text)) if !text.is_empty() => {
                Some(text)
            },
            _ => None,
        };
        Ok(GroupJoinInfo {
            title,
            description_text,
            avatar: info.avatar,
            member_count: info.member_count,
            add_from_invite_link: info.add_from_invite_link.try_into()?,
            revision: info.version,
            pending_admin_approval: info.pending_admin_approval,
        })
    }

    pub fn build_modify_title_action<R: rand::Rng + rand::CryptoRng>(
        &self,
        title: &str,
        rng: &mut R,
    ) -> ModifyTitleAction {
        ModifyTitleAction {
            title: self.encrypt_title(title, rng),
        }
    }

    /// An empty description clears it.
    pub fn build_modify_description_action<R: rand::Rng + rand::CryptoRng>(
        &self,
        description: &str,
        rng: &mut R,
    ) -> ModifyDescriptionAction {
        ModifyDescriptionAction {
            description: self.encrypt_description(Some(description), rng),
        }
    }

    /// `key` names the uploaded avatar (see `GroupsManager::upload_avatar`);
    /// empty clears it.
    pub fn build_modify_avatar_action(&self, key: String) -> ModifyAvatarAction {
        ModifyAvatarAction { avatar: key }
    }

    /// 0 turns disappearing messages off.
    pub fn build_modify_disappearing_messages_timer_action<
        R: rand::Rng + rand::CryptoRng,
    >(
        &self,
        seconds: u32,
        rng: &mut R,
    ) -> ModifyDisappearingMessageTimerAction {
        ModifyDisappearingMessageTimerAction {
            timer: self.encrypt_disappearing_messages_timer(
                Some(&Timer { duration: seconds }),
                rng,
            ),
        }
    }

    /// Who may change the title, description, avatar and timer.
    pub fn build_modify_attributes_access_action(
        &self,
        access: AccessRequired,
    ) -> ModifyAttributesAccessControlAction {
        ModifyAttributesAccessControlAction {
            attributes_access: access.into(),
        }
    }

    /// Who may add members.
    pub fn build_modify_members_access_action(
        &self,
        access: AccessRequired,
    ) -> ModifyMembersAccessControlAction {
        ModifyMembersAccessControlAction {
            members_access: access.into(),
        }
    }

    /// `Unsatisfiable` turns the invite link off, `Any` lets it add members,
    /// `Administrator` makes them ask first.
    pub fn build_modify_invite_link_access_action(
        &self,
        access: AccessRequired,
    ) -> ModifyAddFromInviteLinkAccessControlAction {
        ModifyAddFromInviteLinkAccessControlAction {
            add_from_invite_link_access: access.into(),
        }
    }

    /// Who may set a member label on themselves.
    pub fn build_modify_member_label_access_action(
        &self,
        access: AccessRequired,
    ) -> ModifyMemberLabelAccessControlAction {
        ModifyMemberLabelAccessControlAction {
            member_label_access: access.into(),
        }
    }

    /// Only administrators may send messages while this is on.
    pub fn build_modify_announcements_only_action(
        &self,
        announcements_only: bool,
    ) -> ModifyAnnouncementsOnlyAction {
        ModifyAnnouncementsOnlyAction { announcements_only }
    }

    /// A new password makes the links given out so far useless.
    /// See `GroupInviteLink::new_password`.
    pub fn build_modify_invite_link_password_action(
        &self,
        password: Vec<u8>,
    ) -> ModifyInviteLinkPasswordAction {
        ModifyInviteLinkPasswordAction {
            invite_link_password: password,
        }
    }

    pub fn build_modify_member_role_action(
        &self,
        aci: Aci,
        role: Role,
    ) -> ModifyMemberRoleAction {
        ModifyMemberRoleAction {
            user_id: self.ciphertext_of(aci.into()),
            role: role.into(),
        }
    }

    /// A member's label (and its emoji) next to their name; members set
    /// their own. Both empty clears it.
    pub fn build_modify_member_label_action<R: rand::Rng + rand::CryptoRng>(
        &self,
        aci: Aci,
        label: &str,
        emoji: &str,
        rng: &mut R,
    ) -> ModifyMemberLabelAction {
        let mut encrypt = |text: &str| {
            if text.is_empty() {
                Vec::new()
            } else {
                self.blob(text.as_bytes(), rng)
            }
        };
        let label_string = encrypt(label);
        let label_emoji = encrypt(emoji);
        ModifyMemberLabelAction {
            user_id: self.ciphertext_of(aci.into()),
            label_emoji,
            label_string,
        }
    }

    pub fn build_ban_action(&self, service_id: ServiceId) -> AddMemberBannedAction {
        AddMemberBannedAction {
            added: Some(proto::MemberBanned {
                user_id: self.ciphertext_of(service_id),
                timestamp: 0, // Set by server
            }),
        }
    }

    pub fn build_unban_action(
        &self,
        service_id: ServiceId,
    ) -> DeleteMemberBannedAction {
        DeleteMemberBannedAction {
            deleted_user_id: self.ciphertext_of(service_id),
        }
    }

    /// Lets in someone who asked to join through the invite link.
    pub fn build_promote_requesting_member_action(
        &self,
        aci: Aci,
        role: Role,
    ) -> PromoteMemberPendingAdminApprovalAction {
        PromoteMemberPendingAdminApprovalAction {
            user_id: self.ciphertext_of(aci.into()),
            role: role.into(),
        }
    }

    /// Turns a request to join down, or withdraws one's own.
    pub fn build_remove_requesting_member_action(
        &self,
        aci: Aci,
    ) -> DeleteMemberPendingAdminApprovalAction {
        DeleteMemberPendingAdminApprovalAction {
            deleted_user_id: self.ciphertext_of(aci.into()),
        }
    }

    /// Joins through the invite link, where its access is `Any`. The server
    /// marks the action as a join from the link, and refuses it if it is
    /// marked already ("Invalid field set on action").
    pub fn build_join_from_invite_link_action(
        &self,
        credential: &ExpiringProfileKeyCredential,
        server_public_params: &ServerPublicParams,
    ) -> AddMemberAction {
        self.build_add_member_action_with_credential(
            credential,
            Role::Default,
            server_public_params,
        )
    }

    /// Asks to join through the invite link, where its access is
    /// `Administrator`.
    pub fn build_request_to_join_action(
        &self,
        credential: &ExpiringProfileKeyCredential,
        server_public_params: &ServerPublicParams,
    ) -> AddMemberPendingAdminApprovalAction {
        AddMemberPendingAdminApprovalAction {
            added: Some(proto::MemberPendingAdminApproval {
                user_id: vec![],
                profile_key: vec![],
                presentation: self.create_member_presentation(
                    server_public_params,
                    credential,
                ),
                timestamp: 0,
            }),
        }
    }

    /// Accepts an invitation made to our ACI. The server takes who we are and
    /// our profile key from the presentation.
    pub fn build_accept_invitation_action(
        &self,
        credential: &ExpiringProfileKeyCredential,
        server_public_params: &ServerPublicParams,
    ) -> PromoteMemberPendingProfileKeyAction {
        PromoteMemberPendingProfileKeyAction {
            presentation: self
                .create_member_presentation(server_public_params, credential),
            ..Default::default()
        }
    }

    /// Accepts an invitation made to our PNI (by phone number), telling the
    /// group our ACI.
    pub fn build_accept_pni_invitation_action(
        &self,
        credential: &ExpiringProfileKeyCredential,
        server_public_params: &ServerPublicParams,
    ) -> PromoteMemberPendingPniAciProfileKeyAction {
        PromoteMemberPendingPniAciProfileKeyAction {
            presentation: self
                .create_member_presentation(server_public_params, credential),
            ..Default::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use libsignal_protocol::Pni;
    use rand::Rng;
    use zkgroup::{
        groups::{GroupMasterKey, GroupSecretParams},
        profiles::ProfileKey,
        ServerSecretParams, Timestamp,
    };

    use super::*;
    use crate::groups_v2::{GroupChange, Member};

    const DAY: u64 = 24 * 60 * 60;
    const NOW: u64 = 20_000 * DAY;

    fn operations() -> GroupOperations {
        GroupOperations::new(GroupSecretParams::derive_from_master_key(
            GroupMasterKey::new([3; 32]),
        ))
    }

    fn credential(
        server: &ServerSecretParams,
        aci: Aci,
        profile_key: ProfileKey,
    ) -> ExpiringProfileKeyCredential {
        let mut rng = rand::rng();
        let public = server.get_public_params();
        let context = public.create_profile_key_credential_request_context(
            rng.random(),
            aci,
            profile_key,
        );
        let response = server
            .issue_expiring_profile_key_credential(
                rng.random(),
                &context.get_request(),
                aci,
                profile_key.get_commitment(aci),
                Timestamp::from_epoch_seconds(NOW + 7 * DAY),
            )
            .unwrap();
        public
            .receive_expiring_profile_key_credential(
                &context,
                &response,
                Timestamp::from_epoch_seconds(NOW),
            )
            .unwrap()
    }

    /// Decodes `actions` as members do when a change reaches them; the server
    /// fills in who made it.
    fn as_received(
        ops: &GroupOperations,
        editor: Aci,
        mut actions: proto::group_change::Actions,
    ) -> Vec<GroupChange> {
        actions.source_user_id = ops.ciphertext_of(editor.into());
        actions.group_id =
            ops.group_secret_params.get_group_identifier().to_vec();
        ops.decrypt_group_change(proto::GroupChange {
            actions: actions.encode_to_vec(),
            server_signature: vec![],
            change_epoch: 6,
        })
        .unwrap()
        .changes
    }

    #[test]
    fn attribute_changes_reach_members_as_built() {
        let ops = operations();
        let mut rng = rand::rng();
        let editor = Aci::from_uuid_bytes([1; 16]);
        let actions = proto::group_change::Actions {
            version: 8,
            modify_title: Some(ops.build_modify_title_action("Hikes", &mut rng)),
            modify_description: Some(
                ops.build_modify_description_action("Sundays", &mut rng),
            ),
            modify_avatar: Some(
                ops.build_modify_avatar_action("groups/avatar-key".into()),
            ),
            modify_disappearing_message_timer: Some(
                ops.build_modify_disappearing_messages_timer_action(
                    3600, &mut rng,
                ),
            ),
            modify_attributes_access: Some(
                ops.build_modify_attributes_access_action(
                    AccessRequired::Administrator,
                ),
            ),
            modify_member_access: Some(
                ops.build_modify_members_access_action(AccessRequired::Member),
            ),
            modify_add_from_invite_link_access: Some(
                ops.build_modify_invite_link_access_action(
                    AccessRequired::Administrator,
                ),
            ),
            modify_member_label_access: Some(
                ops.build_modify_member_label_access_action(
                    AccessRequired::Administrator,
                ),
            ),
            modify_announcements_only: Some(
                ops.build_modify_announcements_only_action(true),
            ),
            modify_invite_link_password: Some(
                ops.build_modify_invite_link_password_action(vec![5; 16]),
            ),
            ..Default::default()
        };

        let changes = as_received(&ops, editor, actions);
        let has = |wanted: &dyn Fn(&GroupChange) -> bool| {
            changes.iter().any(wanted)
        };
        assert!(has(&|c| matches!(c, GroupChange::Title(t) if t == "Hikes")));
        assert!(has(&|c| matches!(c,
            GroupChange::Description(Some(d)) if d == "Sundays")));
        assert!(has(&|c| matches!(c,
            GroupChange::Avatar(a) if a == "groups/avatar-key")));
        assert!(has(&|c| matches!(c,
            GroupChange::Timer(Some(Timer { duration: 3600 })))));
        assert!(has(&|c| matches!(c,
            GroupChange::AttributeAccess(AccessRequired::Administrator))));
        assert!(has(&|c| matches!(c,
            GroupChange::MemberAccess(AccessRequired::Member))));
        assert!(has(&|c| matches!(c,
            GroupChange::InviteLinkAccess(AccessRequired::Administrator))));
        assert!(has(&|c| matches!(c,
            GroupChange::MemberLabelAccess(AccessRequired::Administrator))));
        assert!(has(&|c| matches!(c, GroupChange::AnnouncementOnly(true))));
        assert!(has(&|c| matches!(c, GroupChange::InviteLinkPassword(_))));
    }

    #[test]
    fn membership_changes_reach_members_as_built() {
        let ops = operations();
        let mut rng = rand::rng();
        let editor = Aci::from_uuid_bytes([1; 16]);
        let alice = Aci::from_uuid_bytes([2; 16]);
        let bob = Aci::from_uuid_bytes([3; 16]);
        let carol_pni = Pni::from_uuid_bytes([4; 16]);
        let actions = proto::group_change::Actions {
            version: 2,
            delete_members: vec![ops.build_remove_member_action(bob).unwrap()],
            modify_member_roles: vec![ops.build_modify_member_role_action(
                alice,
                Role::Administrator,
            )],
            add_members_banned: vec![ops.build_ban_action(bob.into())],
            delete_members_banned: vec![ops.build_unban_action(carol_pni.into())],
            promote_members_pending_admin_approval: vec![
                ops.build_promote_requesting_member_action(alice, Role::Default),
            ],
            delete_members_pending_admin_approval: vec![
                ops.build_remove_requesting_member_action(bob),
            ],
            add_members_pending_profile_key: vec![ops
                .build_add_pending_member_action(
                    carol_pni.into(),
                    editor,
                    Role::Default,
                )
                .unwrap()],
            modify_member_labels: vec![ops.build_modify_member_label_action(
                editor, "Organiser", "🥾", &mut rng,
            )],
            ..Default::default()
        };

        let changes = as_received(&ops, editor, actions);
        let has = |wanted: &dyn Fn(&GroupChange) -> bool| {
            changes.iter().any(wanted)
        };
        assert!(has(&|c| matches!(c, GroupChange::DeleteMember(a) if *a == bob)));
        assert!(has(&|c| matches!(c, GroupChange::ModifyMemberRole {
            aci, role: Role::Administrator } if *aci == alice)));
        assert!(has(&|c| matches!(c, GroupChange::AddBannedMember(b)
            if b.user_id == ServiceId::from(bob))));
        assert!(has(&|c| matches!(c, GroupChange::DeleteBannedMember(s)
            if *s == ServiceId::from(carol_pni))));
        assert!(has(&|c| matches!(c, GroupChange::PromoteRequestingMember {
            aci, role: Role::Default } if *aci == alice)));
        assert!(has(&|c| matches!(c,
            GroupChange::DeleteRequestingMember(a) if *a == bob)));
        assert!(has(&|c| matches!(c, GroupChange::NewPendingMember(p)
            if p.address == ServiceId::from(carol_pni) && p.added_by_aci == editor)));
        assert!(has(&|c| matches!(c, GroupChange::MemberLabel {
            user_id, label_string: Some(l), label_emoji: Some(e) }
            if *user_id == ServiceId::from(editor) && l == "Organiser" && e == "🥾")));
    }

    #[test]
    fn a_cleared_member_label_is_empty() {
        let ops = operations();
        let me = Aci::from_uuid_bytes([1; 16]);
        let action =
            ops.build_modify_member_label_action(me, "", "", &mut rand::rng());
        assert!(action.label_string.is_empty());
        assert!(action.label_emoji.is_empty());
    }

    #[test]
    fn presentations_prove_who_joins_to_the_server() {
        let mut rng = rand::rng();
        let server = ServerSecretParams::generate(rng.random());
        let public = server.get_public_params();
        let ops = operations();
        let group_public = ops.group_secret_params.get_public_params();
        let me = Aci::from_uuid_bytes([7; 16]);
        let profile_key = ProfileKey::create([9; 32]);
        let credential = credential(&server, me, profile_key);
        let verify = |bytes: &[u8]| {
            let presentation =
                zkgroup::profiles::AnyProfileKeyCredentialPresentation::new(
                    bytes,
                )
                .unwrap();
            server
                .verify_profile_key_credential_presentation(
                    group_public,
                    &presentation,
                    Timestamp::from_epoch_seconds(NOW),
                )
                .unwrap();
            // What the server stores, and members decrypt.
            let member = ops
                .decrypt_group(proto::Group {
                    members: vec![proto::Member {
                        presentation: bytes.to_vec(),
                        role: Role::Default.into(),
                        ..Default::default()
                    }],
                    ..Default::default()
                })
                .unwrap()
                .members
                .remove(0);
            let Member {
                aci,
                profile_key: key,
                ..
            } = member;
            assert_eq!(aci, me);
            assert_eq!(key.get_bytes(), profile_key.get_bytes());
        };

        let join = ops.build_join_from_invite_link_action(&credential, &public);
        assert!(!join.join_from_invite_link);
        verify(&join.added.unwrap().presentation);
        let request = ops.build_request_to_join_action(&credential, &public);
        verify(&request.added.unwrap().presentation);
        let accept = ops.build_accept_invitation_action(&credential, &public);
        assert!(accept.user_id.is_empty() && accept.profile_key.is_empty());
        verify(&accept.presentation);
        let accept_pni =
            ops.build_accept_pni_invitation_action(&credential, &public);
        verify(&accept_pni.presentation);
    }

    #[test]
    fn decrypts_join_info() {
        let ops = operations();
        let mut rng = rand::rng();
        let info = proto::GroupJoinInfo {
            public_key: zkgroup::serialize(
                &ops.group_secret_params.get_public_params(),
            ),
            title: ops.encrypt_title("Book club", &mut rng),
            description: ops.encrypt_description(Some("Monthly"), &mut rng),
            avatar: "groups/xyz".into(),
            member_count: 12,
            add_from_invite_link: AccessRequired::Administrator.into(),
            version: 41,
            pending_admin_approval: true,
        };
        let decoded = proto::GroupJoinInfo::decode(
            info.encode_to_vec().as_slice(),
        )
        .unwrap();
        assert_eq!(
            ops.decrypt_group_join_info(decoded).unwrap(),
            GroupJoinInfo {
                title: "Book club".into(),
                description_text: Some("Monthly".into()),
                avatar: "groups/xyz".into(),
                member_count: 12,
                add_from_invite_link: AccessRequired::Administrator,
                revision: 41,
                pending_admin_approval: true,
            }
        );
    }

    #[test]
    fn avatar_round_trip() {
        let ops = operations();
        let avatar = vec![0x89, b'P', b'N', b'G', 1, 2, 3];
        let ciphertext = ops.encrypt_avatar(&avatar, &mut rand::rng());
        assert_ne!(ciphertext, avatar);
        assert_eq!(ops.decrypt_avatar(&ciphertext), Some(avatar));
    }

    #[test]
    fn a_new_group_decrypts_to_what_was_asked() {
        let mut rng = rand::rng();
        let server = ServerSecretParams::generate(rng.random());
        let public = server.get_public_params();
        let ops = operations();
        let me = Aci::from_uuid_bytes([7; 16]);
        let alice = Aci::from_uuid_bytes([8; 16]);
        let bob_pni = Pni::from_uuid_bytes([9; 16]);
        let own = credential(&server, me, ProfileKey::create([1; 32]));
        let alices = credential(&server, alice, ProfileKey::create([2; 32]));
        let group = ops
            .encrypt_group_with_credentials(
                "Climbing",
                Some("Tuesdays"),
                Some(&Timer { duration: 604800 }),
                None,
                &own,
                &[
                    super::super::GroupMemberCandidate {
                        service_id: alice.into(),
                        credential: Some(alices),
                    },
                    super::super::GroupMemberCandidate {
                        service_id: bob_pni.into(),
                        credential: None,
                    },
                ],
                &public,
                "groups/avatar".into(),
                &mut rng,
            )
            .unwrap();
        // The server answers PUT /v2/groups/ with the group it stored.
        let response = proto::GroupResponse {
            group: Some(group),
            group_send_endorsements_response: vec![],
        };
        let response =
            proto::GroupResponse::decode(response.encode_to_vec().as_slice())
                .unwrap();
        let group = ops.decrypt_group(response.group.unwrap()).unwrap();
        assert_eq!(group.title, "Climbing");
        assert_eq!(group.description_text.as_deref(), Some("Tuesdays"));
        assert_eq!(group.avatar, "groups/avatar");
        assert_eq!(
            group.disappearing_messages_timer,
            Some(Timer { duration: 604800 })
        );
        let roles: Vec<_> =
            group.members.iter().map(|m| (m.aci, m.role)).collect();
        assert_eq!(
            roles,
            vec![(me, Role::Administrator), (alice, Role::Default)]
        );
        assert_eq!(group.members_pending_profile_key.len(), 1);
        assert_eq!(
            group.members_pending_profile_key[0].address,
            ServiceId::from(bob_pni)
        );
        assert_eq!(group.members_pending_profile_key[0].added_by_aci, me);
    }
}
