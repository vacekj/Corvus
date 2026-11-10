//! Which actions a group change takes, given the group as the server has it.
//! No I/O here: the caller fetches the group and the credentials first.

use std::collections::{HashMap, HashSet};

use libsignal_service::{
    groups_v2::{AccessRequired, GroupInviteLink, GroupJoinInfo, GroupOperations, Role},
    proto::group_change::Actions,
    protocol::{Aci, Pni, ServiceId},
    zkgroup::{profiles::ExpiringProfileKeyCredential, ServerPublicParams},
};
use rand::{CryptoRng, Rng};

use crate::model::groups::Group;

/// Changes to make to a group in one go; see `Manager::update_group`. Fields left
/// `None` (or empty) stay as they are, and values the group already has are skipped.
#[derive(Debug, Clone, Default)]
pub struct GroupUpdate {
    pub title: Option<String>,
    /// Empty clears it.
    pub description: Option<String>,
    /// The picture's bytes (JPEG or PNG); empty clears it.
    pub avatar: Option<Vec<u8>>,
    /// Seconds; 0 turns disappearing messages off.
    pub disappearing_messages_timer: Option<u32>,
    /// Who may change title, description, avatar and timer (`Member` or `Administrator`).
    pub attributes_access: Option<AccessRequired>,
    /// Who may add members (`Member` or `Administrator`).
    pub members_access: Option<AccessRequired>,
    /// Who may set a member label (`Member` or `Administrator`).
    pub member_label_access: Option<AccessRequired>,
    /// Only administrators may send messages.
    pub announcements_only: Option<bool>,
    /// Turning the link on makes its password if it has none.
    pub invite_link: Option<InviteLinkAccess>,
    /// A new link password: the links given out so far stop working.
    pub reset_invite_link: bool,
    /// Adds members whose profile key we have (and whose credential the server
    /// gives us), invites the others (also PNIs), lets in those who asked to join,
    /// and lifts their ban if they are banned.
    pub add_members: Vec<ServiceId>,
    /// Removes members, revokes invitations and turns requests to join down.
    pub remove_members: Vec<ServiceId>,
    pub make_admins: Vec<Aci>,
    pub revoke_admins: Vec<Aci>,
    /// Bans, also removing them from the group, its invitations and requests.
    pub ban: Vec<ServiceId>,
    pub unban: Vec<ServiceId>,
    /// Our own label; both empty clears it.
    pub own_member_label: Option<MemberLabel>,
}

/// Who the invite link lets in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InviteLinkAccess {
    Disabled,
    /// Anyone with the link joins.
    Open,
    /// Anyone with the link may ask; an administrator lets them in.
    AdminApproval,
}

impl InviteLinkAccess {
    fn access_required(self) -> AccessRequired {
        match self {
            InviteLinkAccess::Disabled => AccessRequired::Unsatisfiable,
            InviteLinkAccess::Open => AccessRequired::Any,
            InviteLinkAccess::AdminApproval => AccessRequired::Administrator,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MemberLabel {
    pub label: String,
    pub emoji: String,
}

#[derive(Debug, thiserror::Error)]
pub enum GroupError {
    #[error("not a member of the group")]
    NotAMember,
    #[error("already a member of the group")]
    AlreadyMember,
    #[error("not invited to the group")]
    NotInvited,
    #[error("{0} is not a member of the group")]
    NotAMemberOfGroup(String),
    #[error("the group's only administrator has to name another before leaving")]
    LastAdmin,
    #[error("the group's invite link is turned off")]
    InviteLinkClosed,
    #[error("not a group invite link")]
    InvalidInviteLink,
    #[error("the group was ended")]
    Terminated,
    #[error("the group changed too often meanwhile")]
    TooManyConflicts,
}

/// The actions of one change, and who besides the group's members and invitees
/// (before and after it) hears of it.
#[derive(Debug, Clone)]
pub(crate) struct Plan {
    pub(crate) actions: Actions,
    pub(crate) also_tell: Vec<ServiceId>,
}

impl Plan {
    fn new(group: &Group) -> Self {
        Plan {
            actions: Actions {
                version: group.revision + 1,
                ..Default::default()
            },
            also_tell: Vec::new(),
        }
    }

    pub(crate) fn is_empty(&self) -> bool {
        let empty = Actions {
            version: self.actions.version,
            ..Default::default()
        };
        self.actions == empty
    }
}

pub(crate) struct Planner<'a> {
    pub(crate) operations: &'a GroupOperations,
    pub(crate) server_public_params: &'a ServerPublicParams,
    pub(crate) aci: Aci,
    pub(crate) pni: Pni,
}

fn is_pending(group: &Group, service_id: ServiceId) -> bool {
    group
        .pending_members
        .iter()
        .any(|m| m.service_id() == service_id)
}

fn is_requesting(group: &Group, aci: Aci) -> bool {
    group.requesting_members.iter().any(|m| m.aci == aci)
}

fn is_banned(group: &Group, service_id: ServiceId) -> bool {
    group
        .banned_members
        .iter()
        .any(|m| m.service_id() == service_id)
}

fn as_aci(service_id: ServiceId) -> Option<Aci> {
    match service_id {
        ServiceId::Aci(aci) => Some(aci),
        ServiceId::Pni(_) => None,
    }
}

fn dedup(service_ids: &[ServiceId]) -> Vec<ServiceId> {
    let mut seen = HashSet::new();
    service_ids
        .iter()
        .copied()
        .filter(|s| seen.insert(*s))
        .collect()
}

impl Planner<'_> {
    fn is_us(&self, service_id: ServiceId) -> bool {
        service_id == ServiceId::Aci(self.aci) || service_id == ServiceId::Pni(self.pni)
    }

    /// Which of the members to add need a profile key credential: those not in the
    /// group in any way yet.
    pub(crate) fn credentials_needed(&self, group: &Group, update: &GroupUpdate) -> Vec<Aci> {
        dedup(&update.add_members)
            .into_iter()
            .filter(|s| !self.is_us(*s) && !is_pending(group, *s))
            .filter_map(as_aci)
            .filter(|aci| !group.is_member(aci) && !is_requesting(group, *aci))
            .collect()
    }

    /// `avatar_key` names the uploaded avatar when `update.avatar` is set (empty clears).
    pub(crate) fn update<R: Rng + CryptoRng>(
        &self,
        group: &Group,
        update: &GroupUpdate,
        credentials: &HashMap<Aci, ExpiringProfileKeyCredential>,
        avatar_key: Option<String>,
        rng: &mut R,
    ) -> Result<Plan, GroupError> {
        if group.terminated {
            return Err(GroupError::Terminated);
        }
        if !group.is_member(&self.aci) {
            return Err(GroupError::NotAMember);
        }
        let ops = self.operations;
        let mut plan = Plan::new(group);
        let actions = &mut plan.actions;

        if let Some(title) = update.title.as_ref().filter(|t| **t != group.title) {
            actions.modify_title = Some(ops.build_modify_title_action(title, rng));
        }
        if let Some(description) = &update.description {
            if *description != group.description.clone().unwrap_or_default() {
                actions.modify_description =
                    Some(ops.build_modify_description_action(description, rng));
            }
        }
        if let Some(key) = avatar_key {
            if !(key.is_empty() && group.avatar.is_empty()) {
                actions.modify_avatar = Some(ops.build_modify_avatar_action(key));
            }
        }
        if let Some(seconds) = update.disappearing_messages_timer {
            let current = group
                .disappearing_messages_timer
                .as_ref()
                .map_or(0, |t| t.duration);
            if seconds != current {
                actions.modify_disappearing_message_timer =
                    Some(ops.build_modify_disappearing_messages_timer_action(seconds, rng));
            }
        }

        let access = group.access_control.as_ref();
        let differs = |wanted: Option<AccessRequired>,
                       current: Option<AccessRequired>|
         -> Option<AccessRequired> { wanted.filter(|w| Some(*w) != current) };
        if let Some(a) = differs(update.attributes_access, access.map(|a| a.attributes)) {
            actions.modify_attributes_access = Some(ops.build_modify_attributes_access_action(a));
        }
        if let Some(a) = differs(update.members_access, access.map(|a| a.members)) {
            actions.modify_member_access = Some(ops.build_modify_members_access_action(a));
        }
        if let Some(a) = differs(update.member_label_access, access.map(|a| a.member_label)) {
            actions.modify_member_label_access =
                Some(ops.build_modify_member_label_access_action(a));
        }
        if let Some(on) = update
            .announcements_only
            .filter(|on| *on != group.announcements_only)
        {
            actions.modify_announcements_only =
                Some(ops.build_modify_announcements_only_action(on));
        }
        if let Some(link) = update.invite_link {
            let wanted = link.access_required();
            if Some(wanted) != access.map(|a| a.add_from_invite_link) {
                actions.modify_add_from_invite_link_access =
                    Some(ops.build_modify_invite_link_access_action(wanted));
            }
            if link != InviteLinkAccess::Disabled && group.invite_link_password.is_empty() {
                actions.modify_invite_link_password = Some(
                    ops.build_modify_invite_link_password_action(GroupInviteLink::new_password(
                        rng,
                    )),
                );
            }
        }
        if update.reset_invite_link {
            actions.modify_invite_link_password = Some(
                ops.build_modify_invite_link_password_action(GroupInviteLink::new_password(rng)),
            );
        }

        let mut removed = HashSet::new();
        let mut unbanned = HashSet::new();
        let decoding = |e| GroupError::NotAMemberOfGroup(format!("{e}"));

        for target in dedup(&update.add_members) {
            if self.is_us(target) {
                continue;
            }
            if is_banned(group, target) && unbanned.insert(target) {
                actions
                    .delete_members_banned
                    .push(ops.build_unban_action(target));
            }
            let aci = as_aci(target);
            if aci.is_some_and(|aci| group.is_member(&aci)) || is_pending(group, target) {
                continue;
            }
            if let Some(aci) = aci.filter(|aci| is_requesting(group, *aci)) {
                actions
                    .promote_members_pending_admin_approval
                    .push(ops.build_promote_requesting_member_action(aci, Role::Default));
            } else if let Some(credential) = aci.and_then(|aci| credentials.get(&aci)) {
                actions
                    .add_members
                    .push(ops.build_add_member_action_with_credential(
                        credential,
                        Role::Default,
                        self.server_public_params,
                    ));
            } else {
                actions.add_members_pending_profile_key.push(
                    ops.build_add_pending_member_action(target, self.aci, Role::Default)
                        .map_err(decoding)?,
                );
            }
            plan.also_tell.push(target);
        }

        let mut remove = |target: ServiceId, actions: &mut Actions| -> Result<(), GroupError> {
            if self.is_us(target) || !removed.insert(target) {
                return Ok(());
            }
            let aci = as_aci(target);
            if let Some(aci) = aci.filter(|aci| group.is_member(aci)) {
                actions
                    .delete_members
                    .push(ops.build_remove_member_action(aci).map_err(decoding)?);
            } else if is_pending(group, target) {
                actions
                    .delete_members_pending_profile_key
                    .push(ops.build_remove_pending_member_action(target).map_err(decoding)?);
            } else if let Some(aci) = aci.filter(|aci| is_requesting(group, *aci)) {
                actions
                    .delete_members_pending_admin_approval
                    .push(ops.build_remove_requesting_member_action(aci));
            } else {
                return Ok(());
            }
            plan.also_tell.push(target);
            Ok(())
        };
        for target in dedup(&update.remove_members) {
            remove(target, actions)?;
        }
        for target in dedup(&update.ban) {
            if self.is_us(target) {
                continue;
            }
            remove(target, actions)?;
            if !is_banned(group, target) {
                actions.add_members_banned.push(ops.build_ban_action(target));
            }
        }
        for target in dedup(&update.unban) {
            if is_banned(group, target) && unbanned.insert(target) {
                actions
                    .delete_members_banned
                    .push(ops.build_unban_action(target));
            }
        }

        for (admins, role) in [
            (&update.make_admins, Role::Administrator),
            (&update.revoke_admins, Role::Default),
        ] {
            for aci in admins {
                let member = group
                    .members
                    .iter()
                    .find(|m| m.aci == *aci)
                    .ok_or_else(|| GroupError::NotAMemberOfGroup(aci.service_id_string()))?;
                if member.role != role {
                    actions
                        .modify_member_roles
                        .push(ops.build_modify_member_role_action(*aci, role));
                }
            }
        }

        if let Some(wanted) = &update.own_member_label {
            let own = group.members.iter().find(|m| m.aci == self.aci);
            let current = MemberLabel {
                label: own.and_then(|m| m.label.clone()).unwrap_or_default(),
                emoji: own.and_then(|m| m.label_emoji.clone()).unwrap_or_default(),
            };
            if *wanted != current {
                actions
                    .modify_member_labels
                    .push(ops.build_modify_member_label_action(
                        self.aci,
                        &wanted.label,
                        &wanted.emoji,
                        rng,
                    ));
            }
        }

        Ok(plan)
    }

    /// Leaves the group, handing administration to `new_admins`; declines our
    /// invitation, or withdraws our request to join.
    pub(crate) fn leave(&self, group: &Group, new_admins: &[Aci]) -> Result<Plan, GroupError> {
        let ops = self.operations;
        let decoding = |e| GroupError::NotAMemberOfGroup(format!("{e}"));
        let mut plan = Plan::new(group);
        let actions = &mut plan.actions;
        if group.is_member(&self.aci) {
            let other_admins = group
                .members
                .iter()
                .any(|m| m.aci != self.aci && m.role == Role::Administrator);
            let others = group.members.iter().any(|m| m.aci != self.aci);
            if group.is_admin(&self.aci) && others && !other_admins && new_admins.is_empty() {
                return Err(GroupError::LastAdmin);
            }
            for aci in new_admins.iter().filter(|aci| **aci != self.aci) {
                let member = group
                    .members
                    .iter()
                    .find(|m| m.aci == *aci)
                    .ok_or_else(|| GroupError::NotAMemberOfGroup(aci.service_id_string()))?;
                if member.role != Role::Administrator {
                    actions
                        .modify_member_roles
                        .push(ops.build_modify_member_role_action(*aci, Role::Administrator));
                }
            }
            actions
                .delete_members
                .push(ops.build_remove_member_action(self.aci).map_err(decoding)?);
        } else if let Some(invited) = self.invited_as(group) {
            actions
                .delete_members_pending_profile_key
                .push(ops.build_remove_pending_member_action(invited).map_err(decoding)?);
        } else if is_requesting(group, self.aci) {
            actions
                .delete_members_pending_admin_approval
                .push(ops.build_remove_requesting_member_action(self.aci));
        } else {
            return Err(GroupError::NotAMember);
        }
        Ok(plan)
    }

    /// Which of our identities `group` has an invitation for.
    pub(crate) fn invited_as(&self, group: &Group) -> Option<ServiceId> {
        [ServiceId::Aci(self.aci), ServiceId::Pni(self.pni)]
            .into_iter()
            .find(|s| is_pending(group, *s))
    }

    pub(crate) fn accept_invitation(
        &self,
        group: &Group,
        own_credential: &ExpiringProfileKeyCredential,
    ) -> Result<Plan, GroupError> {
        if group.is_member(&self.aci) {
            return Err(GroupError::AlreadyMember);
        }
        let ops = self.operations;
        let spp = self.server_public_params;
        let mut plan = Plan::new(group);
        match self.invited_as(group).ok_or(GroupError::NotInvited)? {
            ServiceId::Aci(_) => plan
                .actions
                .promote_members_pending_profile_key
                .push(ops.build_accept_invitation_action(own_credential, spp)),
            ServiceId::Pni(_) => plan
                .actions
                .promote_members_pending_pni_aci_profile_key
                .push(ops.build_accept_pni_invitation_action(own_credential, spp)),
        }
        Ok(plan)
    }

    /// Joining through the invite link, or asking to; `None` if we asked already.
    /// The flag tells whether this only asks.
    pub(crate) fn join(
        &self,
        info: &GroupJoinInfo,
        own_credential: &ExpiringProfileKeyCredential,
    ) -> Result<Option<(Actions, bool)>, GroupError> {
        if info.pending_admin_approval {
            return Ok(None);
        }
        let ops = self.operations;
        let spp = self.server_public_params;
        let mut actions = Actions {
            version: info.revision + 1,
            ..Default::default()
        };
        let requesting = match info.add_from_invite_link {
            AccessRequired::Any => {
                actions
                    .add_members
                    .push(ops.build_join_from_invite_link_action(own_credential, spp));
                false
            }
            AccessRequired::Administrator => {
                actions
                    .add_members_pending_admin_approval
                    .push(ops.build_request_to_join_action(own_credential, spp));
                true
            }
            _ => return Err(GroupError::InviteLinkClosed),
        };
        Ok(Some((actions, requesting)))
    }
}

/// Who hears of a change: the members and invitees before and after it, and
/// `also_tell`; never us.
pub(crate) fn recipients(
    before: &Group,
    after: Option<&Group>,
    also_tell: &[ServiceId],
    aci: Aci,
    pni: Pni,
) -> Vec<ServiceId> {
    let mut recipients: Vec<ServiceId> = [Some(before), after]
        .into_iter()
        .flatten()
        .flat_map(|group| {
            group
                .members
                .iter()
                .map(|m| ServiceId::Aci(m.aci))
                .chain(group.pending_members.iter().map(|m| m.service_id()))
        })
        .chain(also_tell.iter().copied())
        .filter(|s| *s != ServiceId::Aci(aci) && *s != ServiceId::Pni(pni))
        .collect();
    recipients.sort();
    recipients.dedup();
    recipients
}

#[cfg(test)]
mod tests {
    use libsignal_service::{
        groups_v2::{GroupChange, GroupChanges},
        prelude::{ProfileKey, Timer, Uuid},
        proto,
        zkgroup::{
            groups::{GroupMasterKey, GroupSecretParams},
            ServerSecretParams, Timestamp,
        },
    };
    use libsignal_service::prelude::ProtobufMessage;

    use super::*;
    use crate::model::{
        groups::{AccessControl, BannedMember, Member, PendingMember, RequestingMember},
        ServiceIdType,
    };

    const DAY: u64 = 24 * 60 * 60;

    struct Fixture {
        server: ServerSecretParams,
        public: ServerPublicParams,
        operations: GroupOperations,
        me: Aci,
        my_pni: Pni,
    }

    impl Fixture {
        fn new() -> Self {
            let server = ServerSecretParams::generate(rand::rng().random());
            Fixture {
                public: server.get_public_params(),
                server,
                operations: GroupOperations::new(GroupSecretParams::derive_from_master_key(
                    GroupMasterKey::new([4; 32]),
                )),
                me: aci(1),
                my_pni: Pni::from(Uuid::from_u128(101)),
            }
        }

        fn planner(&self) -> Planner<'_> {
            Planner {
                operations: &self.operations,
                server_public_params: &self.public,
                aci: self.me,
                pni: self.my_pni,
            }
        }

        fn credential(&self, aci: Aci) -> ExpiringProfileKeyCredential {
            let mut rng = rand::rng();
            let key = ProfileKey::create([aci.service_id_binary()[15]; 32]);
            let context =
                self.public
                    .create_profile_key_credential_request_context(rng.random(), aci, key);
            let now = Timestamp::from_epoch_seconds(20_000 * DAY);
            let response = self
                .server
                .issue_expiring_profile_key_credential(
                    rng.random(),
                    &context.get_request(),
                    aci,
                    key.get_commitment(aci),
                    now.add_seconds(7 * DAY),
                )
                .unwrap();
            self.public
                .receive_expiring_profile_key_credential(&context, &response, now)
                .unwrap()
        }

        /// The change as the other members decode it.
        fn received(&self, plan: &Plan) -> GroupChanges {
            let mut actions = plan.actions.clone();
            actions.source_user_id =
                libsignal_service::zkgroup::serialize(&self.operations.group_secret_params.encrypt_service_id(self.me.into()));
            actions.group_id = self
                .operations
                .group_secret_params
                .get_group_identifier()
                .to_vec();
            self.operations
                .decrypt_group_change(proto::GroupChange {
                    actions: actions.encode_to_vec(),
                    server_signature: vec![],
                    change_epoch: 6,
                })
                .unwrap()
        }
    }

    fn aci(n: u128) -> Aci {
        Aci::from(Uuid::from_u128(n))
    }

    fn member(n: u128, role: Role) -> Member {
        Member {
            aci: aci(n),
            role,
            profile_key: ProfileKey::create([n as u8; 32]),
            joined_at_revision: 0,
            label: None,
            label_emoji: None,
        }
    }

    fn pending(service_id: ServiceId) -> PendingMember {
        PendingMember {
            uuid: service_id.raw_uuid(),
            service_id_type: service_id.kind().into(),
            role: Role::Default,
            added_by_aci: aci(1),
            timestamp: 0,
        }
    }

    fn group() -> Group {
        Group {
            title: "Hikes".into(),
            avatar: String::new(),
            disappearing_messages_timer: None,
            access_control: Some(AccessControl {
                attributes: AccessRequired::Member,
                members: AccessRequired::Member,
                add_from_invite_link: AccessRequired::Unsatisfiable,
                member_label: AccessRequired::Member,
            }),
            revision: 7,
            members: vec![member(1, Role::Administrator), member(2, Role::Default)],
            pending_members: vec![pending(Pni::from(Uuid::from_u128(30)).into())],
            requesting_members: vec![RequestingMember {
                aci: aci(40),
                profile_key: ProfileKey::create([40; 32]),
                timestamp: 0,
            }],
            invite_link_password: vec![],
            description: None,
            announcements_only: false,
            banned_members: vec![BannedMember {
                uuid: Uuid::from_u128(50),
                service_id_type: ServiceIdType::AccountIdentity,
                timestamp: 0,
            }],
            terminated: false,
        }
    }

    fn plan(f: &Fixture, group: &Group, update: GroupUpdate) -> Plan {
        let planner = f.planner();
        let credentials = planner
            .credentials_needed(group, &update)
            .into_iter()
            .map(|aci| (aci, f.credential(aci)))
            .collect();
        planner
            .update(group, &update, &credentials, None, &mut rand::rng())
            .unwrap()
    }

    #[test]
    fn builds_on_the_next_revision_and_skips_what_is_set_already() {
        let f = Fixture::new();
        let unchanged = plan(
            &f,
            &group(),
            GroupUpdate {
                title: Some("Hikes".into()),
                description: Some(String::new()),
                disappearing_messages_timer: Some(0),
                members_access: Some(AccessRequired::Member),
                invite_link: Some(InviteLinkAccess::Disabled),
                announcements_only: Some(false),
                add_members: vec![aci(2).into()],
                revoke_admins: vec![aci(2)],
                own_member_label: Some(MemberLabel::default()),
                ..Default::default()
            },
        );
        assert!(unchanged.is_empty());
        assert_eq!(unchanged.actions.version, 8);

        let changed = plan(
            &f,
            &group(),
            GroupUpdate {
                title: Some("Long hikes".into()),
                disappearing_messages_timer: Some(86400),
                attributes_access: Some(AccessRequired::Administrator),
                announcements_only: Some(true),
                ..Default::default()
            },
        );
        assert!(!changed.is_empty());
        let changes = f.received(&changed).changes;
        assert!(changes
            .iter()
            .any(|c| matches!(c, GroupChange::Title(t) if t == "Long hikes")));
        assert!(changes
            .iter()
            .any(|c| matches!(c, GroupChange::Timer(Some(Timer { duration: 86400 })))));
        assert!(changes
            .iter()
            .any(|c| matches!(c, GroupChange::AttributeAccess(AccessRequired::Administrator))));
        assert!(changes
            .iter()
            .any(|c| matches!(c, GroupChange::AnnouncementOnly(true))));
    }

    #[test]
    fn adding_adds_invites_approves_and_unbans() {
        let f = Fixture::new();
        let with_key = aci(10);
        let without_key = aci(11);
        let by_phone: ServiceId = Pni::from(Uuid::from_u128(12)).into();
        let requesting = aci(40);
        let banned = aci(50);
        let group = group();
        let update = GroupUpdate {
            add_members: vec![
                with_key.into(),
                without_key.into(),
                by_phone,
                requesting.into(),
                banned.into(),
                aci(2).into(),                              // a member already
                Pni::from(Uuid::from_u128(30)).into(),      // invited already
                f.me.into(),
            ],
            ..Default::default()
        };
        let planner = f.planner();
        assert_eq!(
            planner.credentials_needed(&group, &update),
            vec![with_key, without_key, banned]
        );
        // The server gave no credential for `without_key`.
        let credentials = HashMap::from([
            (with_key, f.credential(with_key)),
            (banned, f.credential(banned)),
        ]);
        let plan = planner
            .update(&group, &update, &credentials, None, &mut rand::rng())
            .unwrap();
        let a = &plan.actions;
        assert_eq!(a.add_members.len(), 2);
        assert!(a.add_members.iter().all(|m| !m.join_from_invite_link));
        assert_eq!(a.add_members_pending_profile_key.len(), 2);
        assert_eq!(a.promote_members_pending_admin_approval.len(), 1);
        assert_eq!(a.delete_members_banned.len(), 1);

        let changes = f.received(&plan).changes;
        let added: Vec<Aci> = changes
            .iter()
            .filter_map(|c| match c {
                GroupChange::NewMember(m) => Some(m.aci),
                _ => None,
            })
            .collect();
        assert_eq!(added, vec![with_key, banned]);
        let invited: Vec<ServiceId> = changes
            .iter()
            .filter_map(|c| match c {
                GroupChange::NewPendingMember(p) => Some(p.address),
                _ => None,
            })
            .collect();
        assert_eq!(invited, vec![without_key.into(), by_phone]);
        assert!(changes.iter().any(|c| matches!(c,
            GroupChange::PromoteRequestingMember { aci, role: Role::Default } if *aci == requesting)));
        assert!(changes.iter().any(|c| matches!(c,
            GroupChange::DeleteBannedMember(s) if *s == ServiceId::from(banned))));
        assert_eq!(
            plan.also_tell,
            vec![with_key.into(), without_key.into(), by_phone, requesting.into(), banned.into()]
        );
    }

    #[test]
    fn removing_and_banning() {
        let f = Fixture::new();
        let invitee: ServiceId = Pni::from(Uuid::from_u128(30)).into();
        let plan = plan(
            &f,
            &group(),
            GroupUpdate {
                // As Corvus sends a ban: removed and banned in one call.
                remove_members: vec![aci(2).into(), invitee, aci(40).into(), aci(99).into()],
                ban: vec![aci(2).into(), aci(77).into(), aci(50).into()],
                unban: vec![aci(50).into(), aci(78).into()],
                ..Default::default()
            },
        );
        let a = &plan.actions;
        assert_eq!(a.delete_members.len(), 1);
        assert_eq!(a.delete_members_pending_profile_key.len(), 1);
        assert_eq!(a.delete_members_pending_admin_approval.len(), 1);
        // 50 is banned already; 77 is in no list but can be banned.
        assert_eq!(a.add_members_banned.len(), 2);
        assert_eq!(a.delete_members_banned.len(), 1);

        let changes = f.received(&plan).changes;
        assert!(changes
            .iter()
            .any(|c| matches!(c, GroupChange::DeleteMember(a) if *a == aci(2))));
        assert!(changes
            .iter()
            .any(|c| matches!(c, GroupChange::DeletePendingMember(s) if *s == invitee)));
        assert!(changes
            .iter()
            .any(|c| matches!(c, GroupChange::DeleteRequestingMember(a) if *a == aci(40))));
        assert_eq!(plan.also_tell, vec![aci(2).into(), invitee, aci(40).into()]);
    }

    #[test]
    fn admins_and_labels() {
        let f = Fixture::new();
        let plan = plan(
            &f,
            &group(),
            GroupUpdate {
                make_admins: vec![aci(2)],
                own_member_label: Some(MemberLabel {
                    label: "Guide".into(),
                    emoji: "🧭".into(),
                }),
                ..Default::default()
            },
        );
        let changes = f.received(&plan).changes;
        assert!(changes.iter().any(|c| matches!(c,
            GroupChange::ModifyMemberRole { aci: a, role: Role::Administrator } if *a == aci(2))));
        assert!(changes.iter().any(|c| matches!(c,
            GroupChange::MemberLabel { user_id, label_string: Some(l), label_emoji: Some(e) }
                if *user_id == ServiceId::from(f.me) && l == "Guide" && e == "🧭")));

        let error = f
            .planner()
            .update(
                &group(),
                &GroupUpdate {
                    make_admins: vec![aci(40)],
                    ..Default::default()
                },
                &HashMap::new(),
                None,
                &mut rand::rng(),
            )
            .unwrap_err();
        assert!(matches!(error, GroupError::NotAMemberOfGroup(_)));
    }

    #[test]
    fn invite_link_gets_a_password_when_turned_on() {
        let f = Fixture::new();
        let on = plan(
            &f,
            &group(),
            GroupUpdate {
                invite_link: Some(InviteLinkAccess::AdminApproval),
                ..Default::default()
            },
        );
        let password = on
            .actions
            .modify_invite_link_password
            .as_ref()
            .unwrap()
            .invite_link_password
            .clone();
        assert_eq!(password.len(), 16);
        assert_eq!(
            on.actions
                .modify_add_from_invite_link_access
                .as_ref()
                .unwrap()
                .add_from_invite_link_access,
            i32::from(AccessRequired::Administrator)
        );

        let mut with_link = group();
        with_link.invite_link_password = password.clone();
        with_link.access_control.as_mut().unwrap().add_from_invite_link =
            AccessRequired::Administrator;
        let open = plan(
            &f,
            &with_link,
            GroupUpdate {
                invite_link: Some(InviteLinkAccess::Open),
                ..Default::default()
            },
        );
        assert!(open.actions.modify_invite_link_password.is_none());
        let reset = plan(
            &f,
            &with_link,
            GroupUpdate {
                reset_invite_link: true,
                ..Default::default()
            },
        );
        let new_password = &reset
            .actions
            .modify_invite_link_password
            .as_ref()
            .unwrap()
            .invite_link_password;
        assert_ne!(*new_password, password);
        assert!(reset.actions.modify_add_from_invite_link_access.is_none());
        assert!(with_link.invite_link([4; 32]).is_some());
        assert!(group().invite_link([4; 32]).is_none());
    }

    #[test]
    fn a_cleared_avatar_is_only_sent_if_there_is_one() {
        let f = Fixture::new();
        let planner = f.planner();
        let update = GroupUpdate {
            avatar: Some(vec![]),
            ..Default::default()
        };
        let none = planner
            .update(&group(), &update, &HashMap::new(), Some(String::new()), &mut rand::rng())
            .unwrap();
        assert!(none.is_empty());
        let mut with_avatar = group();
        with_avatar.avatar = "groups/old".into();
        let cleared = planner
            .update(&with_avatar, &update, &HashMap::new(), Some(String::new()), &mut rand::rng())
            .unwrap();
        assert_eq!(cleared.actions.modify_avatar.unwrap().avatar, "");
    }

    #[test]
    fn non_members_cannot_change_the_group() {
        let f = Fixture::new();
        let mut group = group();
        group.members.retain(|m| m.aci != f.me);
        assert!(matches!(
            f.planner().update(&group, &GroupUpdate::default(), &HashMap::new(), None, &mut rand::rng()),
            Err(GroupError::NotAMember)
        ));
    }

    #[test]
    fn leaving() {
        let f = Fixture::new();
        let planner = f.planner();
        // The only administrator, with another member.
        assert!(matches!(planner.leave(&group(), &[]), Err(GroupError::LastAdmin)));
        assert!(matches!(
            planner.leave(&group(), &[aci(40)]),
            Err(GroupError::NotAMemberOfGroup(_))
        ));
        let plan = planner.leave(&group(), &[aci(2)]).unwrap();
        let changes = f.received(&plan).changes;
        assert!(changes.iter().any(|c| matches!(c,
            GroupChange::ModifyMemberRole { aci: a, role: Role::Administrator } if *a == aci(2))));
        assert!(changes
            .iter()
            .any(|c| matches!(c, GroupChange::DeleteMember(a) if *a == f.me)));

        let mut alone = group();
        alone.members.retain(|m| m.aci == f.me);
        assert_eq!(planner.leave(&alone, &[]).unwrap().actions.delete_members.len(), 1);

        // Invited by phone number: declining.
        let mut invited = group();
        invited.members.retain(|m| m.aci != f.me);
        invited.pending_members.push(pending(f.my_pni.into()));
        let plan = planner.leave(&invited, &[]).unwrap();
        let changes = f.received(&plan).changes;
        assert!(changes.iter().any(|c| matches!(c,
            GroupChange::DeletePendingMember(s) if *s == ServiceId::from(f.my_pni))));

        // Asked to join: withdrawing.
        let mut requesting = group();
        requesting.members.retain(|m| m.aci != f.me);
        requesting.requesting_members.push(RequestingMember {
            aci: f.me,
            profile_key: ProfileKey::create([1; 32]),
            timestamp: 0,
        });
        let plan = planner.leave(&requesting, &[]).unwrap();
        assert_eq!(plan.actions.delete_members_pending_admin_approval.len(), 1);

        let mut stranger = group();
        stranger.members.retain(|m| m.aci != f.me);
        assert!(matches!(planner.leave(&stranger, &[]), Err(GroupError::NotAMember)));
    }

    #[test]
    fn accepting_an_invitation_by_aci_or_pni() {
        let f = Fixture::new();
        let planner = f.planner();
        let own = f.credential(f.me);
        assert!(matches!(
            planner.accept_invitation(&group(), &own),
            Err(GroupError::AlreadyMember)
        ));
        let mut by_aci = group();
        by_aci.members.retain(|m| m.aci != f.me);
        by_aci.pending_members.push(pending(f.me.into()));
        let plan = planner.accept_invitation(&by_aci, &own).unwrap();
        assert_eq!(plan.actions.promote_members_pending_profile_key.len(), 1);
        assert_eq!(plan.actions.version, 8);

        let mut by_pni = group();
        by_pni.members.retain(|m| m.aci != f.me);
        by_pni.pending_members.push(pending(f.my_pni.into()));
        let plan = planner.accept_invitation(&by_pni, &own).unwrap();
        assert_eq!(plan.actions.promote_members_pending_pni_aci_profile_key.len(), 1);

        let mut neither = group();
        neither.members.retain(|m| m.aci != f.me);
        assert!(matches!(
            planner.accept_invitation(&neither, &own),
            Err(GroupError::NotInvited)
        ));
    }

    #[test]
    fn joining_through_the_link() {
        let f = Fixture::new();
        let planner = f.planner();
        let own = f.credential(f.me);
        let info = |access, pending_admin_approval| GroupJoinInfo {
            title: "Hikes".into(),
            description_text: None,
            avatar: String::new(),
            member_count: 2,
            add_from_invite_link: access,
            revision: 12,
            pending_admin_approval,
        };
        let (actions, requesting) = planner
            .join(&info(AccessRequired::Any, false), &own)
            .unwrap()
            .unwrap();
        assert!(!requesting);
        assert_eq!(actions.version, 13);
        assert_eq!(actions.add_members.len(), 1);
        let (actions, requesting) = planner
            .join(&info(AccessRequired::Administrator, false), &own)
            .unwrap()
            .unwrap();
        assert!(requesting);
        assert_eq!(actions.add_members_pending_admin_approval.len(), 1);
        assert!(planner
            .join(&info(AccessRequired::Administrator, true), &own)
            .unwrap()
            .is_none());
        assert!(matches!(
            planner.join(&info(AccessRequired::Unsatisfiable, false), &own),
            Err(GroupError::InviteLinkClosed)
        ));
    }

    #[test]
    fn recipients_are_members_and_invitees_before_and_after_but_not_us() {
        let f = Fixture::new();
        let before = group();
        let mut after = group();
        after.members.retain(|m| m.aci != aci(2));
        after.members.push(member(3, Role::Default));
        after.pending_members.push(pending(f.my_pni.into()));
        let mut got = recipients(&before, Some(&after), &[aci(40).into()], f.me, f.my_pni);
        got.sort();
        let mut expected: Vec<ServiceId> = vec![
            aci(2).into(),
            aci(3).into(),
            aci(40).into(),
            Pni::from(Uuid::from_u128(30)).into(),
        ];
        expected.sort();
        assert_eq!(got, expected);
    }
}
