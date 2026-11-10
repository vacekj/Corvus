//! Storage Service: reading contacts, groups and the account record into the
//! store, and writing changes back so other devices see them.

use libsignal_service::{
    groups_v2::{GroupsManager, InMemoryCredentialsCache},
    master_key::StorageServiceKey,
    prelude::{phonenumber, ProfileKey, Uuid},
    proto::{
        sync_message::{self, Content as SyncContent},
        ContactRecord, SyncMessage,
    },
    protocol::{Aci, ServiceId},
    push_service::PushService,
    storage_service::{
        AccountRecordExt, BlockedList, ContactPatch, ContactRecordExt, ContactTarget,
        GroupV2Patch, StorageChange, StorageState,
    },
    StorageService,
};
use tracing::{debug, info, warn};

use crate::model::contacts::Contact;
use crate::store::Store;
use crate::{Error, Manager};

use super::Registered;

/// Writes per [`Manager::update_storage`] before giving up on version conflicts.
const MAX_WRITE_ATTEMPTS: usize = 5;

/// The storage key, derived from the account entropy pool when we have one
/// (it is the root and survives master key rotation), else from the master key.
pub(super) async fn storage_service_key<S: Store>(
    store: &S,
) -> Result<StorageServiceKey, Error<S::Error>> {
    if let Some(aep) = store.fetch_account_entropy_pool().await? {
        return Ok(StorageServiceKey::from_account_entropy_pool(&aep));
    }
    if let Some(master_key) = store.fetch_master_key().await? {
        return Ok(StorageServiceKey::from_master_key(&master_key));
    }
    Err(Error::MissingKeyError("master_key".into()))
}

/// The persisted snapshot; an unreadable one is treated as absent.
pub(super) async fn load_state<S: Store>(
    store: &S,
) -> Result<Option<StorageState>, Error<S::Error>> {
    let Some(bytes) = store.storage_service_state().await? else {
        return Ok(None);
    };
    match StorageState::from_bytes(&bytes) {
        Ok(state) => Ok(Some(state)),
        Err(error) => {
            warn!(%error, "discarding unreadable storage service snapshot");
            Ok(None)
        }
    }
}

async fn save_state<S: Store>(store: &S, state: &StorageState) -> Result<(), Error<S::Error>> {
    store
        .save_storage_service_state(Some(&state.to_bytes()))
        .await?;
    Ok(())
}

/// Blocked contacts and groups according to the last snapshot.
pub(super) async fn blocked_list<S: Store>(store: &S) -> BlockedList {
    match load_state(store).await {
        Ok(Some(state)) => state.blocked(),
        _ => BlockedList::default(),
    }
}

/// `discoverableByPhoneNumber` for `PUT /v1/accounts/attributes`: the
/// account record's setting, or discoverable when it is not known yet.
pub(super) async fn discoverable_by_phone_number<S: Store>(store: &S) -> bool {
    match load_state(store).await {
        Ok(Some(state)) => state
            .account()
            .map(|a| a.discoverable_by_phone_number())
            .unwrap_or(true),
        _ => true,
    }
}

/// Brings the snapshot up to date, saves contacts to the store and fetches
/// groups that are new to us.
pub(super) async fn sync_storage_service<S: Store>(
    store: &S,
    push_service: PushService,
    groups_manager: &mut GroupsManager<InMemoryCredentialsCache>,
) -> Result<StorageState, Error<S::Error>> {
    let key = storage_service_key(store).await?;
    let storage = StorageService::new(push_service, key).await?;
    let previous = load_state(store).await?;
    let previous_version = previous.as_ref().map(StorageState::version);
    let state = storage.fetch_state(previous).await?;
    save_state(store, &state).await?;

    if previous_version == Some(state.version()) {
        debug!(version = state.version(), "storage service unchanged");
    }
    info!(
        version = state.version(),
        contacts = state.contacts().count(),
        groups = state.groups_v2().count(),
        "synced storage service"
    );

    let mut store = store.clone();
    for record in state.contacts() {
        if let Err(error) = save_contact_record(&mut store, record).await {
            warn!(%error, "failed to save contact from the storage service");
        }
    }
    for group in state.groups_v2() {
        if let Err(error) = super::save_unknown_group(&store, groups_manager, &group.master_key).await
        {
            warn!(%error, "failed to fetch group listed in the storage service");
        }
    }
    Ok(state)
}

/// Display name for presage's [`Contact::name`]: the address-book name, else
/// the address-book nickname, else the profile name.
pub fn contact_record_name(record: &ContactRecord) -> String {
    fn join(given: &str, family: &str) -> String {
        [given.trim(), family.trim()]
            .iter()
            .filter(|s| !s.is_empty())
            .copied()
            .collect::<Vec<_>>()
            .join(" ")
    }
    let system = join(&record.system_given_name, &record.system_family_name);
    if !system.is_empty() {
        return system;
    }
    if !record.system_nickname.trim().is_empty() {
        return record.system_nickname.trim().to_owned();
    }
    join(&record.given_name, &record.family_name)
}

/// Merges a contact record into the stored [`Contact`] (keeping its expire
/// timer, avatar and verification state). `None` if nothing changes.
pub(crate) fn merge_contact_record(
    record: &ContactRecord,
    existing: Option<Contact>,
) -> Option<Contact> {
    let aci = record.aci_uuid()?;
    let name = contact_record_name(record);
    let phone_number = phonenumber::parse(None, &record.e164).ok();
    let profile_key = Some(&record.profile_key).filter(|k| k.len() == 32);

    let is_new = existing.is_none();
    let mut contact = existing.unwrap_or_else(|| Contact {
        uuid: aci,
        phone_number: None,
        name: String::new(),
        verified: Default::default(),
        profile_key: Vec::new(),
        expire_timer: 0,
        expire_timer_version: 2,
        inbox_position: 0,
        avatar: None,
    });
    let mut changed = is_new;
    if !name.is_empty() && contact.name != name {
        contact.name = name;
        changed = true;
    }
    if phone_number.is_some() && contact.phone_number != phone_number {
        contact.phone_number = phone_number;
        changed = true;
    }
    if let Some(profile_key) = profile_key {
        if &contact.profile_key != profile_key {
            contact.profile_key = profile_key.clone();
            changed = true;
        }
    }
    changed.then_some(contact)
}

async fn save_contact_record<S: Store>(
    store: &mut S,
    record: &ContactRecord,
) -> Result<(), Error<S::Error>> {
    let Some(aci) = record.aci_uuid() else {
        return Ok(());
    };
    let existing = store.contact_by_id(&ServiceId::Aci(Aci::from(aci))).await?;
    let Some(contact) = merge_contact_record(record, existing) else {
        return Ok(());
    };
    store.save_contact(&contact).await?;
    if let Ok(bytes) = <[u8; 32]>::try_from(record.profile_key.as_slice()) {
        store
            .upsert_profile_key(&aci, ProfileKey::create(bytes))
            .await?;
    }
    Ok(())
}

impl<S: Store> Manager<S, Registered> {
    /// The Storage Service key (from the account entropy pool or master key).
    pub async fn storage_service_key(&self) -> Result<StorageServiceKey, Error<S::Error>> {
        storage_service_key(&self.store).await
    }

    /// The last Storage Service snapshot, without touching the network.
    pub async fn storage_state(&self) -> Result<Option<StorageState>, Error<S::Error>> {
        load_state(&self.store).await
    }

    /// Fetches what changed in the Storage Service (everything the first
    /// time), saves contacts to the store and fetches new groups. Contacts from
    /// the Storage Service take precedence over the legacy contact sync.
    pub async fn sync_storage_service(&mut self) -> Result<StorageState, Error<S::Error>> {
        let mut groups_manager = Box::pin(self.groups_manager()).await?;
        sync_storage_service(
            &self.store,
            self.identified_push_service(),
            &mut groups_manager,
        )
        .await
    }

    /// Applies `changes` to the latest Storage Service state and writes a new
    /// manifest, merging with concurrent writes from other devices. Tells our
    /// other devices to fetch the new manifest when something was written.
    pub async fn update_storage(
        &mut self,
        changes: &[StorageChange],
    ) -> Result<StorageState, Error<S::Error>> {
        let key = storage_service_key(&self.store).await?;
        let storage = StorageService::new(self.identified_push_service(), key).await?;
        let previous = load_state(&self.store).await?;
        let state = storage.fetch_state(previous).await?;
        let device_id = self.state.data.device_id.unwrap_or(1);
        let outcome = storage
            .commit(state, changes, device_id, MAX_WRITE_ATTEMPTS)
            .await?;
        save_state(&self.store, &outcome.state).await?;

        for change in changes {
            if let StorageChange::Contact { target, .. } = change {
                if let Some(record) = outcome.state.contact(target) {
                    save_contact_record(&mut self.store, record).await?;
                }
            }
        }
        if outcome.written {
            info!(version = outcome.state.version(), "wrote storage manifest");
            if let Err(error) = self.send_storage_manifest_fetch_latest().await {
                warn!(%error, "failed to tell other devices about the new storage manifest");
            }
        }
        Ok(outcome.state)
    }

    /// Changes a contact record (names, nickname, note, archived, hidden, ...),
    /// creating it if absent.
    pub async fn update_contact_record(
        &mut self,
        target: ContactTarget,
        patch: ContactPatch,
    ) -> Result<StorageState, Error<S::Error>> {
        self.update_storage(&[StorageChange::Contact { target, patch }])
            .await
    }

    /// Changes a group record (blocked, archived, muted, ...), creating it if absent.
    pub async fn update_group_record(
        &mut self,
        master_key: [u8; 32],
        patch: GroupV2Patch,
    ) -> Result<StorageState, Error<S::Error>> {
        self.update_storage(&[StorageChange::GroupV2 {
            master_key: master_key.to_vec(),
            patch,
        }])
        .await
    }

    /// Blocks or unblocks a contact: Storage Service record plus a
    /// `SyncMessage.Blocked` with the full list. Blocking also stops sharing
    /// our profile with them, as the official clients do.
    pub async fn set_contact_blocked(
        &mut self,
        target: ContactTarget,
        blocked: bool,
    ) -> Result<StorageState, Error<S::Error>> {
        let patch = ContactPatch {
            blocked: Some(blocked),
            whitelisted: blocked.then_some(false),
            ..Default::default()
        };
        let state = self.update_contact_record(target, patch).await?;
        self.send_blocked_sync(&state.blocked()).await?;
        Ok(state)
    }

    /// Blocks or unblocks a group: Storage Service record plus a
    /// `SyncMessage.Blocked` with the full list.
    pub async fn set_group_blocked(
        &mut self,
        master_key: [u8; 32],
        blocked: bool,
    ) -> Result<StorageState, Error<S::Error>> {
        let patch = GroupV2Patch {
            blocked: Some(blocked),
            whitelisted: blocked.then_some(false),
            ..Default::default()
        };
        let state = self.update_group_record(master_key, patch).await?;
        self.send_blocked_sync(&state.blocked()).await?;
        Ok(state)
    }

    /// Sends the complete blocked list to our other devices.
    pub async fn send_blocked_sync(&mut self, blocked: &BlockedList) -> Result<(), Error<S::Error>> {
        let message = SyncMessage {
            content: Some(SyncContent::Blocked(blocked.to_sync_message())),
            ..SyncMessage::with_padding(&mut rand::rng())
        };
        self.new_message_sender()
            .await?
            .send_sync_message(message)
            .await?;
        Ok(())
    }

    /// Asks our other devices to fetch the latest storage manifest.
    pub async fn send_storage_manifest_fetch_latest(&mut self) -> Result<(), Error<S::Error>> {
        let message = SyncMessage {
            content: Some(SyncContent::FetchLatest(sync_message::FetchLatest {
                r#type: Some(sync_message::fetch_latest::Type::StorageManifest.into()),
            })),
            ..SyncMessage::with_padding(&mut rand::rng())
        };
        self.new_message_sender()
            .await?
            .send_sync_message(message)
            .await?;
        Ok(())
    }
}

/// Contact target for a service id.
pub fn contact_target(service_id: &ServiceId) -> ContactTarget {
    match service_id {
        ServiceId::Aci(aci) => ContactTarget::aci(Uuid::from(*aci)),
        ServiceId::Pni(pni) => ContactTarget {
            pni: Some(Uuid::from(*pni)),
            ..Default::default()
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ACI: Uuid = Uuid::from_u128(0x3c1f0e53_5d8a_4a85_9e0c_6b1b1f3c2a01);

    fn record() -> ContactRecord {
        ContactRecord {
            aci: ACI.to_string(),
            e164: "+420777000111".into(),
            given_name: "Profile".into(),
            family_name: "Name".into(),
            profile_key: vec![7; 32],
            ..Default::default()
        }
    }

    #[test]
    fn name_preference() {
        let mut r = record();
        assert_eq!(contact_record_name(&r), "Profile Name");
        r.system_nickname = "Nick".into();
        assert_eq!(contact_record_name(&r), "Nick");
        r.system_given_name = "Address".into();
        r.system_family_name = "Book".into();
        assert_eq!(contact_record_name(&r), "Address Book");
    }

    #[test]
    fn merge_into_new_and_existing_contacts() {
        let created = merge_contact_record(&record(), None).expect("new contact");
        assert_eq!(created.uuid, ACI);
        assert_eq!(created.name, "Profile Name");
        assert_eq!(
            created.phone_number,
            Some(phonenumber::parse(None, "+420777000111").unwrap())
        );
        assert_eq!(created.profile_key, vec![7; 32]);

        // Unchanged: nothing to save.
        assert!(merge_contact_record(&record(), Some(created)).is_none());

        // Storage names win over a legacy contact-sync name; local-only fields stay.
        let legacy = Contact {
            uuid: ACI,
            phone_number: None,
            name: "Legacy".into(),
            verified: Default::default(),
            profile_key: Vec::new(),
            expire_timer: 3600,
            expire_timer_version: 3,
            inbox_position: 4,
            avatar: None,
        };
        let mut r = record();
        r.system_given_name = "Address".into();
        let merged = merge_contact_record(&r, Some(legacy)).expect("changed");
        assert_eq!(merged.name, "Address");
        assert_eq!(merged.expire_timer, 3600);
        assert_eq!(merged.expire_timer_version, 3);
        assert_eq!(merged.inbox_position, 4);
    }

    #[test]
    fn records_without_aci_are_skipped() {
        let r = ContactRecord {
            e164: "+420777000111".into(),
            ..Default::default()
        };
        assert!(merge_contact_record(&r, None).is_none());
    }

    #[test]
    fn contact_targets() {
        let aci = ServiceId::Aci(Aci::from(ACI));
        assert_eq!(contact_target(&aci), ContactTarget::aci(ACI));
    }
}
