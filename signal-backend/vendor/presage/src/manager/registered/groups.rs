//! Creating, changing, joining and leaving groups (Groups v2).
//!
//! Every change is built on the group as the server has it now, sent as a
//! `PATCH /v2/groups/`, rebuilt and retried on a 409 conflict, stored, and then
//! told to the members (and invitees) as a `DataMessage.groupV2` carrying the
//! server-signed change, as Signal's apps do.
//!
//! Adapted in part from whisperfish/presage#448 (Rafael Bachmann).

mod plan;

use std::collections::HashMap;

use libsignal_service::{
    content::{Content, ContentBody, Metadata},
    groups_v2::{
        decrypt_group, is_group_change_conflict, AccessControl as ServiceAccessControl,
        AccessRequired, GroupInviteLink, GroupJoinInfo, GroupMemberCandidate, GroupOperations,
        GroupsManager, InMemoryCredentialsCache, Timer,
    },
    prelude::{MessageSenderError, ProfileKey, ProtobufMessage},
    proto::{DataMessage, GroupContextV2},
    protocol::{Aci, ServiceId},
    unidentified_access::UnidentifiedAccess,
    zkgroup::{
        groups::{GroupMasterKey, GroupSecretParams},
        profiles::ExpiringProfileKeyCredential,
        GroupIdentifierBytes, GroupMasterKeyBytes, ServerPublicParams,
    },
};
use rand::{rng, Rng};
use tracing::{debug, warn};

use super::{ensure_data_message_timestamp, Registered};
use crate::{
    model::groups::{Group, RequestingMember},
    store::{Store, Thread},
    Error, Manager,
};

pub use plan::{GroupError, GroupUpdate, InviteLinkAccess, MemberLabel};
use plan::{recipients, Plan, Planner};

/// How often a change is rebuilt after someone else changed the group meanwhile.
const ATTEMPTS: usize = 3;

/// A group to create; see [`Manager::create_group`].
#[derive(Debug, Clone, Default)]
pub struct NewGroup {
    pub title: String,
    pub description: Option<String>,
    /// Added if we have their profile key (and the server gives us their
    /// credential), invited otherwise.
    pub members: Vec<ServiceId>,
    /// JPEG or PNG.
    pub avatar: Option<Vec<u8>>,
    /// Seconds; 0 for none.
    pub disappearing_messages_timer: u32,
}

#[derive(Debug, Clone)]
pub struct CreatedGroup {
    pub master_key: GroupMasterKeyBytes,
    pub group: Group,
    /// Of the message telling the members.
    pub timestamp: u64,
}

#[derive(Debug, Clone)]
pub struct GroupChangeOutcome {
    /// The group's revision after the change (unchanged if there was nothing to do).
    pub revision: u32,
    /// The group as stored now; `None` if it could not be fetched after the change.
    pub group: Option<Group>,
    /// Of the message telling the members; `None` if nothing changed or no one was told.
    pub timestamp: Option<u64>,
}

#[derive(Debug, Clone)]
pub enum GroupJoinOutcome {
    /// We are in; the members were told at `timestamp`.
    Joined { group: Group, timestamp: u64 },
    /// An administrator has to let us in. Meanwhile the group is stored with what
    /// the link shows of it, and us among its requesting members.
    Requested { group: Group },
    AlreadyMember { group: Group },
}

/// The group identifier (what signal-cli calls the group id) of a master key.
pub fn group_identifier(master_key: GroupMasterKeyBytes) -> GroupIdentifierBytes {
    GroupSecretParams::derive_from_master_key(GroupMasterKey::new(master_key))
        .get_group_identifier()
}

fn operations(master_key: GroupMasterKeyBytes) -> GroupOperations {
    GroupOperations::new(GroupSecretParams::derive_from_master_key(
        GroupMasterKey::new(master_key),
    ))
}

fn now_millis() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("after 1970")
        .as_millis() as u64
}

type Groups = GroupsManager<InMemoryCredentialsCache>;

impl<S: Store> Manager<S, Registered> {
    fn planner<'a>(
        &self,
        operations: &'a GroupOperations,
        server_public_params: &'a ServerPublicParams,
    ) -> Planner<'a> {
        Planner {
            operations,
            server_public_params,
            aci: self.state.data.service_ids.aci(),
            pni: self.state.data.service_ids.pni(),
        }
    }

    /// Creates a group with us as its administrator, tells the members, and stores
    /// it. Signal's defaults: members may edit details and add members, the invite
    /// link is off.
    pub async fn create_group(
        &mut self,
        new_group: NewGroup,
    ) -> Result<CreatedGroup, Error<S::Error>> {
        let master_key: GroupMasterKeyBytes = rng().random();
        let ops = operations(master_key);
        let mut groups = Box::pin(self.groups_manager()).await?;
        let server_public_params = groups.server_public_params().clone();
        let own = self.state.data.service_ids.aci();
        let pni = self.state.data.service_ids.pni();
        let own_credential = self
            .profile_key_credential(own, self.state.data.profile_key(), &server_public_params)
            .await?;

        let mut candidates = Vec::new();
        let mut seen = Vec::new();
        for member in new_group.members {
            if member == ServiceId::Aci(own) || member == ServiceId::Pni(pni) || seen.contains(&member)
            {
                continue;
            }
            seen.push(member);
            let credential = match member {
                ServiceId::Aci(aci) => self.member_credential(aci, &server_public_params).await?,
                ServiceId::Pni(_) => None,
            };
            candidates.push(GroupMemberCandidate {
                service_id: member,
                credential,
            });
        }

        let avatar = new_group.avatar.filter(|a| !a.is_empty());
        let avatar_key = match &avatar {
            Some(avatar) => groups.upload_avatar(&mut rng(), &master_key, avatar).await?,
            None => String::new(),
        };
        let access = ServiceAccessControl {
            attributes: AccessRequired::Member,
            members: AccessRequired::Member,
            add_from_invite_link: AccessRequired::Unsatisfiable,
            member_label: AccessRequired::Member,
        };
        let timer = (new_group.disappearing_messages_timer > 0).then_some(Timer {
            duration: new_group.disappearing_messages_timer,
        });
        let encrypted = ops
            .encrypt_group_with_credentials(
                &new_group.title,
                new_group.description.as_deref().filter(|d| !d.is_empty()),
                timer.as_ref(),
                Some(&access),
                &own_credential,
                &candidates,
                &server_public_params,
                avatar_key,
                &mut rng(),
            )
            .map_err(|e| Error::ServiceError(e.into()))?;
        let created = groups
            .create_group(&mut rng(), &master_key, encrypted)
            .await?;
        let group: Group = ops
            .decrypt_group(created)
            .map_err(|e| Error::ServiceError(e.into()))?
            .into();
        self.store.save_group(master_key, group.clone()).await?;
        if let Some(avatar) = &avatar {
            self.store.save_group_avatar(master_key, avatar).await?;
        }

        let told = recipients(&group, None, &[], own, pni);
        let timestamp = self.send_group_update(master_key, &told, 0, None).await?;
        Ok(CreatedGroup {
            master_key,
            group,
            timestamp,
        })
    }

    /// Changes a group we are a member of; see [`GroupUpdate`]. Everything in
    /// `update` goes in one change, which the server accepts or refuses whole.
    pub async fn update_group(
        &mut self,
        master_key: GroupMasterKeyBytes,
        update: GroupUpdate,
    ) -> Result<GroupChangeOutcome, Error<S::Error>> {
        let ops = operations(master_key);
        let mut groups = Box::pin(self.groups_manager()).await?;
        let server_public_params = groups.server_public_params().clone();
        // Uploaded once, whatever the attempts below.
        let avatar_key = match &update.avatar {
            Some(avatar) if avatar.is_empty() => Some(String::new()),
            Some(avatar) => Some(groups.upload_avatar(&mut rng(), &master_key, avatar).await?),
            None => None,
        };
        let mut credentials = HashMap::new();
        for attempt in 1..=ATTEMPTS {
            let before = match self.fetch_and_store(&mut groups, master_key).await {
                Err(Error::ServiceError(
                    libsignal_service::push_service::ServiceError::Unauthorized,
                )) => return Err(GroupError::NotAMember.into()),
                other => other?,
            };
            let planner = self.planner(&ops, &server_public_params);
            for aci in planner.credentials_needed(&before, &update) {
                if credentials.contains_key(&aci) {
                    continue;
                }
                if let Some(credential) = self.member_credential(aci, &server_public_params).await? {
                    credentials.insert(aci, credential);
                }
            }
            let plan = planner.update(&before, &update, &credentials, avatar_key.clone(), &mut rng())?;
            if plan.is_empty() {
                return Ok(GroupChangeOutcome {
                    revision: before.revision,
                    group: Some(before),
                    timestamp: None,
                });
            }
            match groups
                .modify_group(&mut rng(), &master_key, plan.actions.clone())
                .await
            {
                Ok(signed) => {
                    let outcome = self
                        .finish_change(&mut groups, master_key, before, plan, signed, false)
                        .await?;
                    if let Some(avatar) = update.avatar.as_ref().filter(|a| !a.is_empty()) {
                        self.store.save_group_avatar(master_key, avatar).await?;
                    }
                    return Ok(outcome);
                }
                Err(error) if is_group_change_conflict(&error) && attempt < ATTEMPTS => {
                    debug!(attempt, "the group changed meanwhile; building the change again");
                }
                Err(error) if is_group_change_conflict(&error) => {
                    return Err(GroupError::TooManyConflicts.into())
                }
                Err(error) => return Err(error.into()),
            }
        }
        Err(GroupError::TooManyConflicts.into())
    }

    /// Joins a group we were invited to, by ACI or by phone number (PNI).
    pub async fn accept_group_invitation(
        &mut self,
        master_key: GroupMasterKeyBytes,
    ) -> Result<GroupChangeOutcome, Error<S::Error>> {
        let ops = operations(master_key);
        let mut groups = Box::pin(self.groups_manager()).await?;
        let server_public_params = groups.server_public_params().clone();
        let own_credential = self
            .profile_key_credential(
                self.state.data.service_ids.aci(),
                self.state.data.profile_key(),
                &server_public_params,
            )
            .await?;
        for attempt in 1..=ATTEMPTS {
            let before = self.current_group(&mut groups, master_key).await?;
            let plan = self
                .planner(&ops, &server_public_params)
                .accept_invitation(&before, &own_credential)?;
            match groups
                .modify_group(&mut rng(), &master_key, plan.actions.clone())
                .await
            {
                Ok(signed) => {
                    return self
                        .finish_change(&mut groups, master_key, before, plan, signed, false)
                        .await
                }
                Err(error) if is_group_change_conflict(&error) && attempt < ATTEMPTS => {
                    debug!(attempt, "the group changed meanwhile; accepting again");
                }
                Err(error) => return Err(error.into()),
            }
        }
        Err(GroupError::TooManyConflicts.into())
    }

    /// Leaves a group, naming `new_admins` (members) administrators in the same
    /// change; required when we are its only administrator and others remain.
    /// Also declines an invitation, or withdraws a request to join.
    pub async fn leave_group(
        &mut self,
        master_key: GroupMasterKeyBytes,
        new_admins: &[Aci],
    ) -> Result<GroupChangeOutcome, Error<S::Error>> {
        let ops = operations(master_key);
        let mut groups = Box::pin(self.groups_manager()).await?;
        let server_public_params = groups.server_public_params().clone();
        let own = self.state.data.service_ids.aci();
        for attempt in 1..=ATTEMPTS {
            let before = self.current_group(&mut groups, master_key).await?;
            let plan = self
                .planner(&ops, &server_public_params)
                .leave(&before, new_admins)?;
            // Only a request to join needs the link's password to withdraw.
            let requesting = !plan.actions.delete_members_pending_admin_approval.is_empty();
            let result = if requesting {
                let link = GroupInviteLink {
                    master_key,
                    password: before.invite_link_password.clone(),
                };
                groups
                    .modify_group_from_invite_link(&mut rng(), &link, plan.actions.clone())
                    .await
            } else {
                groups
                    .modify_group(&mut rng(), &master_key, plan.actions.clone())
                    .await
            };
            match result {
                Ok(signed) if requesting => {
                    // As Signal-Android: a withdrawn request is told to no one.
                    let revision = plan.actions.version;
                    let group = self.store_left(master_key, before, revision, own).await?;
                    drop(signed);
                    return Ok(GroupChangeOutcome {
                        revision,
                        group: Some(group),
                        timestamp: None,
                    });
                }
                Ok(signed) => {
                    return self
                        .finish_change(&mut groups, master_key, before, plan, signed, true)
                        .await
                }
                Err(error) if is_group_change_conflict(&error) && attempt < ATTEMPTS => {
                    debug!(attempt, "the group changed meanwhile; leaving again");
                }
                Err(error) => return Err(error.into()),
            }
        }
        Err(GroupError::TooManyConflicts.into())
    }

    /// What a group shows to whoever holds its invite link.
    pub async fn group_join_info(
        &mut self,
        link: &GroupInviteLink,
    ) -> Result<GroupJoinInfo, Error<S::Error>> {
        let mut groups = Box::pin(self.groups_manager()).await?;
        Ok(groups.group_join_info(&mut rng(), link).await?)
    }

    /// Joins a group through its invite link (`https://signal.group/#…`, see
    /// [`GroupInviteLink::parse`]), or asks to where administrators approve
    /// members. A request is told to no one, as in Signal-Android; administrators
    /// see it when they next fetch the group.
    pub async fn join_group_via_link(
        &mut self,
        link: &GroupInviteLink,
    ) -> Result<GroupJoinOutcome, Error<S::Error>> {
        let master_key = link.master_key;
        let ops = operations(master_key);
        let mut groups = Box::pin(self.groups_manager()).await?;
        let server_public_params = groups.server_public_params().clone();
        let own = self.state.data.service_ids.aci();
        let pni = self.state.data.service_ids.pni();

        if self
            .store
            .group(master_key)
            .await?
            .is_some_and(|g| g.is_member(&own))
        {
            if let Ok(group) = self.fetch_and_store(&mut groups, master_key).await {
                if group.is_member(&own) {
                    return Ok(GroupJoinOutcome::AlreadyMember { group });
                }
            }
        }

        let own_credential = self
            .profile_key_credential(own, self.state.data.profile_key(), &server_public_params)
            .await?;
        let mut attempt = 0;
        let (info, change) = loop {
            attempt += 1;
            let info = groups.group_join_info(&mut rng(), link).await?;
            let Some((actions, requesting)) = self
                .planner(&ops, &server_public_params)
                .join(&info, &own_credential)?
            else {
                break (info, None);
            };
            let revision = actions.version;
            match groups
                .modify_group_from_invite_link(&mut rng(), link, actions)
                .await
            {
                Ok(signed) => break (info, Some((signed, revision, requesting))),
                Err(error) if is_group_change_conflict(&error) && attempt < ATTEMPTS => {
                    debug!(attempt, "the group changed meanwhile; joining again");
                }
                Err(error) => return Err(error.into()),
            }
        };

        if let Some((signed, revision, false)) = change {
            let group = self.fetch_and_store(&mut groups, master_key).await?;
            let told = recipients(&group, None, &[], own, pni);
            let timestamp = self
                .send_group_update(master_key, &told, revision, Some(&signed))
                .await?;
            return Ok(GroupJoinOutcome::Joined { group, timestamp });
        }

        // Not a member: the server shows us nothing more until we are let in.
        let known = self.store.group(master_key).await?;
        let (members, pending_members, banned_members) = known
            .map(|k| (k.members, k.pending_members, k.banned_members))
            .unwrap_or_default();
        let mut group = Group {
            title: info.title,
            avatar: info.avatar.clone(),
            disappearing_messages_timer: None,
            access_control: Some(crate::model::groups::AccessControl {
                attributes: AccessRequired::Member,
                members: AccessRequired::Member,
                add_from_invite_link: info.add_from_invite_link,
                member_label: AccessRequired::Member,
            }),
            revision: change.as_ref().map_or(info.revision, |(_, r, _)| *r),
            members,
            pending_members,
            requesting_members: vec![RequestingMember {
                aci: own,
                profile_key: self.state.data.profile_key(),
                timestamp: now_millis(),
            }],
            invite_link_password: link.password.clone(),
            description: info.description_text,
            announcements_only: false,
            banned_members,
            terminated: false,
        };
        let avatar = if info.avatar.is_empty() {
            None
        } else {
            match groups
                .retrieve_avatar(&info.avatar, ops.group_secret_params)
                .await
            {
                Ok(avatar) => avatar,
                Err(error) => {
                    warn!(%error, "failed to fetch the group's avatar");
                    None
                }
            }
        };
        if avatar.is_none() {
            // Leave the path out, so a later fetch of the group gets the picture.
            group.avatar = String::new();
        }
        self.store.save_group(master_key, group.clone()).await?;
        // After the group: the picture refers to it.
        if let Some(avatar) = avatar {
            self.store.save_group_avatar(master_key, &avatar).await?;
        }
        Ok(GroupJoinOutcome::Requested { group })
    }

    /// Fetches the group from the server whatever revision is stored, and stores
    /// it. Fails with `Unauthorized` if we are not in it.
    pub async fn fetch_group(
        &mut self,
        master_key: GroupMasterKeyBytes,
    ) -> Result<Group, Error<S::Error>> {
        let mut groups = Box::pin(self.groups_manager()).await?;
        self.fetch_and_store(&mut groups, master_key).await
    }

    async fn fetch_and_store(
        &self,
        groups: &mut Groups,
        master_key: GroupMasterKeyBytes,
    ) -> Result<Group, Error<S::Error>> {
        let encrypted = groups.fetch_encrypted_group(&mut rng(), &master_key).await?;
        let group: Group = decrypt_group(&master_key, encrypted)?.into();
        self.store.save_group(master_key, group.clone()).await?;
        Ok(group)
    }

    /// The group as the server has it, or as stored when the server shows it no
    /// more (to an invitee or someone asking to join).
    async fn current_group(
        &self,
        groups: &mut Groups,
        master_key: GroupMasterKeyBytes,
    ) -> Result<Group, Error<S::Error>> {
        match self.fetch_and_store(groups, master_key).await {
            Ok(group) => Ok(group),
            Err(Error::ServiceError(libsignal_service::push_service::ServiceError::Unauthorized)) => {
                self.store
                    .group(master_key)
                    .await?
                    .ok_or(Error::UnknownGroup)
            }
            Err(error) => Err(error),
        }
    }

    /// Stores the group without us, at `revision`, and marks it left.
    async fn store_left(
        &self,
        master_key: GroupMasterKeyBytes,
        mut group: Group,
        revision: u32,
        own: Aci,
    ) -> Result<Group, Error<S::Error>> {
        let pni = self.state.data.service_ids.pni();
        group.members.retain(|m| m.aci != own);
        group
            .pending_members
            .retain(|m| m.service_id() != ServiceId::Aci(own) && m.service_id() != ServiceId::Pni(pni));
        group.requesting_members.retain(|m| m.aci != own);
        group.revision = revision;
        self.store.save_group(master_key, group.clone()).await?;
        self.store.mark_group_left(master_key).await?;
        Ok(group)
    }

    /// Stores the group as it is after the change and tells the members.
    async fn finish_change(
        &mut self,
        groups: &mut Groups,
        master_key: GroupMasterKeyBytes,
        before: Group,
        plan: Plan,
        signed: libsignal_service::proto::GroupChange,
        leaving: bool,
    ) -> Result<GroupChangeOutcome, Error<S::Error>> {
        let own = self.state.data.service_ids.aci();
        let pni = self.state.data.service_ids.pni();
        let revision = plan.actions.version;
        let after = if leaving {
            // The server no longer shows us the group.
            Some(self.store_left(master_key, before.clone(), revision, own).await?)
        } else {
            match self.fetch_and_store(groups, master_key).await {
                Ok(group) => Some(group),
                Err(error) => {
                    warn!(%error, "failed to fetch the group after changing it");
                    None
                }
            }
        };
        let told = recipients(&before, after.as_ref(), &plan.also_tell, own, pni);
        let timestamp = self
            .send_group_update(master_key, &told, revision, Some(&signed))
            .await?;
        Ok(GroupChangeOutcome {
            revision,
            group: after,
            timestamp: Some(timestamp),
        })
    }

    /// Sends the group context (and the signed change, if any) to `recipients`,
    /// with a sync transcript to our other devices. Failures to reach a recipient
    /// are only logged: the change is made already. Returns the timestamp.
    async fn send_group_update(
        &mut self,
        master_key: GroupMasterKeyBytes,
        recipients: &[ServiceId],
        revision: u32,
        signed: Option<&libsignal_service::proto::GroupChange>,
    ) -> Result<u64, Error<S::Error>> {
        let timestamp = now_millis();
        let mut content_body: ContentBody = DataMessage {
            group_v2: Some(GroupContextV2 {
                master_key: Some(master_key.to_vec()),
                revision: Some(revision),
                group_change: signed.map(|s| s.encode_to_vec()),
            }),
            ..Default::default()
        }
        .into();
        ensure_data_message_timestamp(&mut content_body, timestamp);

        let mut sender = self.new_message_sender().await?;
        let sender_certificate = self.sender_certificate().await?;
        let mut targets = Vec::new();
        for recipient in recipients {
            let unidentified_access =
                self.store
                    .profile_key(recipient)
                    .await?
                    .map(|profile_key| UnidentifiedAccess {
                        key: profile_key.derive_access_key().to_vec(),
                        certificate: sender_certificate.clone(),
                    });
            targets.push((*recipient, unidentified_access, false));
        }
        for result in sender
            .send_message_to_group(targets, content_body.clone(), timestamp, false)
            .await
        {
            match result {
                Ok(_) | Err(MessageSenderError::NotFound { .. }) => {}
                Err(error) => warn!(%error, "failed to tell a member of a group change"),
            }
        }

        let own = self.state.data.service_ids.aci();
        let at = chrono::DateTime::from_timestamp_millis(timestamp as i64).unwrap_or_default();
        let content = Content {
            metadata: Metadata {
                sender: own.into(),
                destination: own.into(),
                sender_device: self.state.device_id(),
                server_guid: None,
                client_timestamp: at,
                server_timestamp: at,
                needs_receipt: false,
                unidentified_sender: false,
                was_plaintext: false,
                pni_verified: None,
            },
            body: content_body,
        };
        self.store
            .save_message(&Thread::Group(master_key), content)
            .await?;
        Ok(timestamp)
    }

    /// The credential of a member to add, if we have their profile key and the
    /// server gives it; otherwise they are invited instead, as Signal's apps do.
    async fn member_credential(
        &self,
        aci: Aci,
        server_public_params: &ServerPublicParams,
    ) -> Result<Option<ExpiringProfileKeyCredential>, Error<S::Error>> {
        let Some(profile_key) = self.store.profile_key(&aci.into()).await? else {
            return Ok(None);
        };
        Ok(self
            .profile_key_credential(aci, profile_key, server_public_params)
            .await
            .inspect_err(|error| warn!(%error, "no profile key credential; inviting instead"))
            .ok())
    }

    async fn profile_key_credential(
        &self,
        aci: Aci,
        profile_key: ProfileKey,
        server_public_params: &ServerPublicParams,
    ) -> Result<ExpiringProfileKeyCredential, Error<S::Error>> {
        let mut websocket = self.identified_websocket(false).await?;
        Ok(websocket
            .retrieve_expiring_profile_key_credential(
                &mut rng(),
                aci,
                profile_key,
                server_public_params,
            )
            .await?)
    }
}
