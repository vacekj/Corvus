//! A local snapshot of the Storage Service (manifest plus decrypted records)
//! and the pure read-modify-write planning on top of it.
//!
//! Records are immutable on the server: changing one means inserting it under
//! a fresh random id, deleting the old id and listing the new id in a manifest
//! whose version is one higher. A write is planned from [`StorageChange`]s
//! (field-level patches), so after a version conflict the same changes can be
//! re-applied to the newer remote state, keeping whatever other devices wrote
//! in the meantime.

use std::collections::BTreeMap;

use prost::Message;
use rand::{CryptoRng, Rng};
use uuid::Uuid;
use zkgroup::groups::{GroupMasterKey, GroupSecretParams};

use crate::libsignal_account_keys::{AccountEntropyPool, SvrKey};
use crate::master_key::{MasterKey, StorageServiceKey};
use crate::proto::{
    account_record, manifest_record, storage_record,
    sync_message, AccountRecord, ContactRecord, GroupV2Record, ManifestRecord,
    StorageRecord,
};

use super::{wire, StorageServiceError};

pub use crate::proto::account_record::PhoneNumberSharingMode;
pub use crate::proto::manifest_record::identifier::Type as StorageRecordType;

/// Length of a storage item id.
pub const STORAGE_ID_LEN: usize = 16;

/// `StorageRecord` oneof field numbers.
const CONTACT_FIELD: u32 = 1;
const GROUP_V2_FIELD: u32 = 3;
const ACCOUNT_FIELD: u32 = 4;

impl StorageServiceKey {
    /// Storage key of an account whose root is an [`AccountEntropyPool`]
    /// (what a linked device receives at provisioning and in `SyncMessage.Keys`).
    pub fn from_account_entropy_pool(aep: &AccountEntropyPool) -> Self {
        Self {
            inner: SvrKey::new(aep.derive_svr_key())
                .derive_storage_service_key(),
        }
    }
}

impl MasterKey {
    /// The master key ("SVR key") derived from an [`AccountEntropyPool`].
    pub fn from_account_entropy_pool(aep: &AccountEntropyPool) -> Self {
        Self {
            inner: aep.derive_svr_key(),
        }
    }
}

/// A decrypted storage record together with the exact plaintext it was
/// decoded from (needed to carry unknown fields through a modification).
#[derive(Clone, Debug, PartialEq)]
pub struct StoredRecord {
    pub id: Vec<u8>,
    pub record: StorageRecord,
    plaintext: Vec<u8>,
}

impl StoredRecord {
    fn new(id: Vec<u8>, plaintext: Vec<u8>) -> Result<Self, StorageServiceError> {
        let record = StorageRecord::decode(plaintext.as_slice())?;
        Ok(Self {
            id,
            record,
            plaintext,
        })
    }

    pub fn plaintext(&self) -> &[u8] {
        &self.plaintext
    }
}

/// Persisted form of a [`StorageState`].
#[derive(Clone, PartialEq, prost::Message)]
struct PersistedState {
    #[prost(bytes = "vec", tag = "1")]
    manifest: Vec<u8>,
    #[prost(message, repeated, tag = "2")]
    records: Vec<PersistedRecord>,
}

#[derive(Clone, PartialEq, prost::Message)]
struct PersistedRecord {
    #[prost(bytes = "vec", tag = "1")]
    id: Vec<u8>,
    #[prost(bytes = "vec", tag = "2")]
    plaintext: Vec<u8>,
}

/// Local snapshot of the Storage Service: the latest known manifest and every
/// record of it that has been read.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct StorageState {
    manifest: ManifestRecord,
    records: BTreeMap<Vec<u8>, StoredRecord>,
}

impl StorageState {
    /// A state with a manifest and no records read yet.
    pub fn new(manifest: ManifestRecord) -> Self {
        Self {
            manifest,
            records: BTreeMap::new(),
        }
    }

    pub fn version(&self) -> u64 {
        self.manifest.version
    }

    pub fn manifest(&self) -> &ManifestRecord {
        &self.manifest
    }

    pub fn record_ikm(&self) -> Option<&[u8]> {
        Some(self.manifest.record_ikm.as_slice()).filter(|ikm| !ikm.is_empty())
    }

    /// Moves to a newer manifest, keeping the records it still lists.
    pub fn rebase(mut self, manifest: ManifestRecord) -> Self {
        let listed: std::collections::HashSet<&[u8]> =
            manifest.identifiers.iter().map(|i| i.raw.as_slice()).collect();
        self.records.retain(|id, _| listed.contains(id.as_slice()));
        self.manifest = manifest;
        self
    }

    /// Ids listed in the manifest whose records have not been read yet.
    pub fn missing_ids(&self) -> Vec<Vec<u8>> {
        self.manifest
            .identifiers
            .iter()
            .filter(|i| !self.records.contains_key(&i.raw))
            .map(|i| i.raw.clone())
            .collect()
    }

    /// Adds a decrypted record read from the server. Ids the manifest does not
    /// list are ignored.
    pub fn insert_plaintext(
        &mut self,
        id: Vec<u8>,
        plaintext: Vec<u8>,
    ) -> Result<(), StorageServiceError> {
        if self.manifest.identifiers.iter().any(|i| i.raw == id) {
            let record = StoredRecord::new(id.clone(), plaintext)?;
            self.records.insert(id, record);
        }
        Ok(())
    }

    pub fn records(&self) -> impl Iterator<Item = &StoredRecord> {
        self.records.values()
    }

    pub fn contacts(&self) -> impl Iterator<Item = &ContactRecord> {
        self.records.values().filter_map(|r| match &r.record.record {
            Some(storage_record::Record::Contact(c)) => Some(c),
            _ => None,
        })
    }

    pub fn groups_v2(&self) -> impl Iterator<Item = &GroupV2Record> {
        self.records.values().filter_map(|r| match &r.record.record {
            Some(storage_record::Record::GroupV2(g)) => Some(g),
            _ => None,
        })
    }

    pub fn account(&self) -> Option<&AccountRecord> {
        self.records.values().find_map(|r| match &r.record.record {
            Some(storage_record::Record::Account(a)) => Some(a),
            _ => None,
        })
    }

    pub fn contact(&self, target: &ContactTarget) -> Option<&ContactRecord> {
        self.find_contact(target).map(|(_, c)| c)
    }

    pub fn group_v2(&self, master_key: &[u8]) -> Option<&GroupV2Record> {
        self.find_group_v2(master_key).map(|(_, g)| g)
    }

    /// Everything marked blocked in contact and group records.
    pub fn blocked(&self) -> BlockedList {
        let mut blocked = BlockedList::default();
        for contact in self.contacts().filter(|c| c.blocked) {
            match (contact.aci_uuid(), contact.e164.as_str()) {
                (Some(aci), e164) => {
                    blocked.acis.push(aci);
                    if !e164.is_empty() {
                        blocked.e164s.push(e164.to_owned());
                    }
                },
                (None, e164) if !e164.is_empty() => {
                    blocked.e164s.push(e164.to_owned())
                },
                _ => {},
            }
        }
        for group in self.groups_v2().filter(|g| g.blocked) {
            if let Ok(key) = <[u8; 32]>::try_from(group.master_key.as_slice())
            {
                blocked.group_master_keys.push(key);
            }
        }
        blocked
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        PersistedState {
            manifest: self.manifest.encode_to_vec(),
            records: self
                .records
                .values()
                .map(|r| PersistedRecord {
                    id: r.id.clone(),
                    plaintext: r.plaintext.clone(),
                })
                .collect(),
        }
        .encode_to_vec()
    }

    pub fn from_bytes(bytes: &[u8]) -> Result<Self, StorageServiceError> {
        let persisted = PersistedState::decode(bytes)?;
        let mut state =
            Self::new(ManifestRecord::decode(persisted.manifest.as_slice())?);
        for record in persisted.records {
            state.insert_plaintext(record.id, record.plaintext)?;
        }
        Ok(state)
    }

    fn find_contact(
        &self,
        target: &ContactTarget,
    ) -> Option<(&[u8], &ContactRecord)> {
        self.records.values().find_map(|r| match &r.record.record {
            Some(storage_record::Record::Contact(c)) if target.matches(c) => {
                Some((r.id.as_slice(), c))
            },
            _ => None,
        })
    }

    fn find_group_v2(
        &self,
        master_key: &[u8],
    ) -> Option<(&[u8], &GroupV2Record)> {
        self.records.values().find_map(|r| match &r.record.record {
            Some(storage_record::Record::GroupV2(g))
                if g.master_key == master_key =>
            {
                Some((r.id.as_slice(), g))
            },
            _ => None,
        })
    }

    fn find_account(&self) -> Option<(&[u8], &AccountRecord)> {
        self.records.values().find_map(|r| match &r.record.record {
            Some(storage_record::Record::Account(a)) => {
                Some((r.id.as_slice(), a))
            },
            _ => None,
        })
    }

    /// Plans the write that applies `changes` on top of this state.
    ///
    /// Returns `None` when the changes are already in effect. Records that
    /// change get a fresh id; unknown fields of the original are kept.
    pub fn plan_write<R: Rng + CryptoRng>(
        &self,
        changes: &[StorageChange],
        source_device: u32,
        rng: &mut R,
    ) -> Result<Option<PendingWrite>, StorageServiceError> {
        let mut working = self.clone();
        let mut inserted: Vec<Vec<u8>> = Vec::new();
        let mut deleted: Vec<Vec<u8>> = Vec::new();

        for change in changes {
            let (old_id, field, kind, mut inner, known) = match change {
                StorageChange::Contact { target, patch } => {
                    let (old_id, mut record) =
                        match working.find_contact(target) {
                            Some((id, c)) => (Some(id.to_vec()), c.clone()),
                            None => (None, target.new_record()),
                        };
                    let before = record.clone();
                    patch.apply(&mut record);
                    if old_id.is_some() && record == before {
                        continue;
                    }
                    (old_id, CONTACT_FIELD, StorageRecordType::Contact, record.encode_to_vec(), wire::CONTACT_RECORD_FIELDS)
                },
                StorageChange::GroupV2 { master_key, patch } => {
                    let (old_id, mut record) =
                        match working.find_group_v2(master_key) {
                            Some((id, g)) => (Some(id.to_vec()), g.clone()),
                            None => (
                                None,
                                GroupV2Record {
                                    master_key: master_key.to_vec(),
                                    ..Default::default()
                                },
                            ),
                        };
                    let before = record.clone();
                    patch.apply(&mut record);
                    if old_id.is_some() && record == before {
                        continue;
                    }
                    (old_id, GROUP_V2_FIELD, StorageRecordType::Groupv2, record.encode_to_vec(), wire::GROUP_V2_RECORD_FIELDS)
                },
                StorageChange::Account(patch) => {
                    let (old_id, mut record) = match working.find_account() {
                        Some((id, a)) => (Some(id.to_vec()), a.clone()),
                        None => (None, AccountRecord::default()),
                    };
                    let before = record.clone();
                    patch.apply(&mut record);
                    if old_id.is_some() && record == before {
                        continue;
                    }
                    (old_id, ACCOUNT_FIELD, StorageRecordType::Account, record.encode_to_vec(), wire::ACCOUNT_RECORD_FIELDS)
                },
            };
            if let Some(old) = old_id.as_ref().and_then(|id| working.records.get(id))
            {
                if let Some(old_inner) =
                    wire::length_delimited(&old.plaintext, field)?
                {
                    inner.extend(wire::unknown_fields(old_inner, known)?);
                }
            }
            let plaintext = wire::encode_length_delimited(field, &inner);

            match old_id {
                // Created or changed earlier in this batch: not on the server
                // yet, so update it in place.
                Some(id) if inserted.contains(&id) => {
                    let record = StoredRecord::new(id.clone(), plaintext)?;
                    working.records.insert(id, record);
                },
                old_id => {
                    let mut id = vec![0u8; STORAGE_ID_LEN];
                    rng.fill_bytes(&mut id);
                    if let Some(old_id) = old_id {
                        working.records.remove(&old_id);
                        working.manifest.identifiers.retain(|i| i.raw != old_id);
                        deleted.push(old_id);
                    }
                    working.manifest.identifiers.push(
                        manifest_record::Identifier {
                            raw: id.clone(),
                            r#type: kind.into(),
                        },
                    );
                    working
                        .records
                        .insert(id.clone(), StoredRecord::new(id.clone(), plaintext)?);
                    inserted.push(id);
                },
            }
        }

        if inserted.is_empty() && deleted.is_empty() {
            return Ok(None);
        }

        let manifest = ManifestRecord {
            version: self.manifest.version + 1,
            source_device,
            identifiers: working.manifest.identifiers,
            record_ikm: self.manifest.record_ikm.clone(),
        };
        let inserts = inserted
            .into_iter()
            .map(|id| {
                let plaintext = working.records[&id].plaintext.clone();
                (id, plaintext)
            })
            .collect();
        Ok(Some(PendingWrite {
            manifest,
            inserts,
            deletes: deleted,
        }))
    }

    /// The state after `pending` was accepted by the server.
    pub fn apply_write(
        &self,
        pending: &PendingWrite,
    ) -> Result<Self, StorageServiceError> {
        let mut state = self.clone().rebase(pending.manifest.clone());
        for (id, plaintext) in &pending.inserts {
            state.insert_plaintext(id.clone(), plaintext.clone())?;
        }
        Ok(state)
    }
}

/// A planned Storage Service write: the next manifest, the records to insert
/// (id, plaintext `StorageRecord`) and the ids to delete.
#[derive(Clone, Debug, PartialEq)]
pub struct PendingWrite {
    pub manifest: ManifestRecord,
    pub inserts: Vec<(Vec<u8>, Vec<u8>)>,
    pub deletes: Vec<Vec<u8>>,
}

/// A field-level change to one record.
#[derive(Clone, Debug, PartialEq)]
pub enum StorageChange {
    /// Changes the contact matching `target`, creating it if absent.
    Contact {
        target: ContactTarget,
        patch: ContactPatch,
    },
    /// Changes the group record for `master_key`, creating it if absent.
    GroupV2 {
        master_key: Vec<u8>,
        patch: GroupV2Patch,
    },
    Account(AccountPatch),
}

/// Identifies a contact record. A record matches on ACI when both sides
/// have one, else on PNI, else on phone number.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ContactTarget {
    pub aci: Option<Uuid>,
    pub pni: Option<Uuid>,
    /// E.164, e.g. `+15551234567`.
    pub e164: Option<String>,
}

impl ContactTarget {
    pub fn aci(aci: Uuid) -> Self {
        Self {
            aci: Some(aci),
            ..Default::default()
        }
    }

    fn matches(&self, record: &ContactRecord) -> bool {
        if let (Some(a), Some(b)) = (self.aci, record.aci_uuid()) {
            return a == b;
        }
        if let (Some(a), Some(b)) = (self.pni, record.pni_uuid()) {
            return a == b;
        }
        matches!(
            (self.e164.as_deref(), record.e164.as_str()),
            (Some(a), b) if !a.is_empty() && a == b
        )
    }

    fn new_record(&self) -> ContactRecord {
        let mut record = ContactRecord::default();
        if let Some(aci) = self.aci {
            record.aci = aci.to_string();
            record.aci_binary = aci.as_bytes().to_vec();
        }
        if let Some(pni) = self.pni {
            record.pni = pni.to_string();
            record.pni_binary = pni.as_bytes().to_vec();
        }
        if let Some(e164) = &self.e164 {
            record.e164 = e164.clone();
        }
        record
    }
}

/// Convenience accessors on [`ContactRecord`].
pub trait ContactRecordExt {
    /// ACI from `aciBinary`, falling back to the `aci` string.
    fn aci_uuid(&self) -> Option<Uuid>;
    /// PNI from `pniBinary`, falling back to the `pni` string (with or
    /// without the `PNI:` prefix).
    fn pni_uuid(&self) -> Option<Uuid>;
    /// Nickname as (given, family); `None` when unset.
    fn nickname_parts(&self) -> Option<(&str, &str)>;
}

impl ContactRecordExt for ContactRecord {
    fn aci_uuid(&self) -> Option<Uuid> {
        Uuid::from_slice(&self.aci_binary)
            .ok()
            .or_else(|| Uuid::parse_str(&self.aci).ok())
            .filter(|u| !u.is_nil())
    }

    fn pni_uuid(&self) -> Option<Uuid> {
        Uuid::from_slice(&self.pni_binary)
            .ok()
            .or_else(|| {
                Uuid::parse_str(
                    self.pni.strip_prefix("PNI:").unwrap_or(&self.pni),
                )
                .ok()
            })
            .filter(|u| !u.is_nil())
    }

    fn nickname_parts(&self) -> Option<(&str, &str)> {
        self.nickname
            .as_ref()
            .map(|n| (n.given.as_str(), n.family.as_str()))
            .filter(|(g, f)| !g.is_empty() || !f.is_empty())
    }
}

/// Fields to change on a [`ContactRecord`]; `None` leaves a field as is.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ContactPatch {
    /// Profile given name.
    pub given_name: Option<String>,
    /// Profile family name.
    pub family_name: Option<String>,
    /// Address-book given name.
    pub system_given_name: Option<String>,
    /// Address-book family name.
    pub system_family_name: Option<String>,
    pub system_nickname: Option<String>,
    /// Nickname given name; with an empty family name too, clears the nickname.
    pub nickname_given_name: Option<String>,
    pub nickname_family_name: Option<String>,
    pub note: Option<String>,
    pub e164: Option<String>,
    pub profile_key: Option<Vec<u8>>,
    pub blocked: Option<bool>,
    /// Profile sharing / accepted message request.
    pub whitelisted: Option<bool>,
    pub archived: Option<bool>,
    pub marked_unread: Option<bool>,
    pub muted_until_timestamp: Option<u64>,
    pub hide_story: Option<bool>,
    /// Hidden from the chat list (a hidden message request).
    pub hidden: Option<bool>,
}

fn set<T: Clone>(field: &mut T, value: &Option<T>) {
    if let Some(value) = value {
        *field = value.clone();
    }
}

impl ContactPatch {
    pub fn apply(&self, record: &mut ContactRecord) {
        set(&mut record.given_name, &self.given_name);
        set(&mut record.family_name, &self.family_name);
        set(&mut record.system_given_name, &self.system_given_name);
        set(&mut record.system_family_name, &self.system_family_name);
        set(&mut record.system_nickname, &self.system_nickname);
        set(&mut record.note, &self.note);
        set(&mut record.e164, &self.e164);
        set(&mut record.profile_key, &self.profile_key);
        set(&mut record.blocked, &self.blocked);
        set(&mut record.whitelisted, &self.whitelisted);
        set(&mut record.archived, &self.archived);
        set(&mut record.marked_unread, &self.marked_unread);
        set(&mut record.muted_until_timestamp, &self.muted_until_timestamp);
        set(&mut record.hide_story, &self.hide_story);
        set(&mut record.hidden, &self.hidden);
        if self.nickname_given_name.is_some()
            || self.nickname_family_name.is_some()
        {
            let mut nickname = record.nickname.take().unwrap_or_default();
            set(&mut nickname.given, &self.nickname_given_name);
            set(&mut nickname.family, &self.nickname_family_name);
            if !nickname.given.is_empty() || !nickname.family.is_empty() {
                record.nickname = Some(nickname);
            }
        }
    }
}

/// Fields to change on a [`GroupV2Record`]; `None` leaves a field as is.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct GroupV2Patch {
    pub blocked: Option<bool>,
    pub whitelisted: Option<bool>,
    pub archived: Option<bool>,
    pub marked_unread: Option<bool>,
    pub muted_until_timestamp: Option<u64>,
    pub dont_notify_for_mentions_if_muted: Option<bool>,
    pub hide_story: Option<bool>,
}

impl GroupV2Patch {
    pub fn apply(&self, record: &mut GroupV2Record) {
        set(&mut record.blocked, &self.blocked);
        set(&mut record.whitelisted, &self.whitelisted);
        set(&mut record.archived, &self.archived);
        set(&mut record.marked_unread, &self.marked_unread);
        set(&mut record.muted_until_timestamp, &self.muted_until_timestamp);
        set(
            &mut record.dont_notify_for_mentions_if_muted,
            &self.dont_notify_for_mentions_if_muted,
        );
        set(&mut record.hide_story, &self.hide_story);
    }
}

/// Fields to change on the [`AccountRecord`]; `None` leaves a field as is.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct AccountPatch {
    pub given_name: Option<String>,
    pub family_name: Option<String>,
    pub profile_key: Option<Vec<u8>>,
    pub avatar_url_path: Option<String>,
    pub read_receipts: Option<bool>,
    pub sealed_sender_indicators: Option<bool>,
    pub typing_indicators: Option<bool>,
    pub link_previews: Option<bool>,
    pub phone_number_sharing_mode: Option<PhoneNumberSharingMode>,
    /// `true` = not discoverable by phone number.
    pub unlisted_phone_number: Option<bool>,
    pub universal_expire_timer: Option<u32>,
    pub pinned_conversations: Option<Vec<account_record::PinnedConversation>>,
    /// Empty string clears the username.
    pub username: Option<String>,
    /// `Some(None)` clears the username link.
    pub username_link: Option<Option<account_record::UsernameLink>>,
    pub note_to_self_archived: Option<bool>,
    pub note_to_self_marked_unread: Option<bool>,
}

impl AccountPatch {
    pub fn apply(&self, record: &mut AccountRecord) {
        set(&mut record.given_name, &self.given_name);
        set(&mut record.family_name, &self.family_name);
        set(&mut record.profile_key, &self.profile_key);
        set(&mut record.avatar_url_path, &self.avatar_url_path);
        set(&mut record.read_receipts, &self.read_receipts);
        set(
            &mut record.sealed_sender_indicators,
            &self.sealed_sender_indicators,
        );
        set(&mut record.typing_indicators, &self.typing_indicators);
        set(&mut record.link_previews, &self.link_previews);
        if let Some(mode) = self.phone_number_sharing_mode {
            record.phone_number_sharing_mode = mode.into();
        }
        set(&mut record.unlisted_phone_number, &self.unlisted_phone_number);
        set(
            &mut record.universal_expire_timer,
            &self.universal_expire_timer,
        );
        set(&mut record.pinned_conversations, &self.pinned_conversations);
        set(&mut record.username, &self.username);
        set(&mut record.username_link, &self.username_link);
        set(&mut record.note_to_self_archived, &self.note_to_self_archived);
        set(
            &mut record.note_to_self_marked_unread,
            &self.note_to_self_marked_unread,
        );
    }
}

/// Blocked recipients and groups.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct BlockedList {
    pub acis: Vec<Uuid>,
    pub e164s: Vec<String>,
    pub group_master_keys: Vec<[u8; 32]>,
}

impl BlockedList {
    /// The `SyncMessage.Blocked` other devices expect. Group ids are the
    /// group identifiers derived from the master keys.
    pub fn to_sync_message(&self) -> sync_message::Blocked {
        sync_message::Blocked {
            numbers: self.e164s.clone(),
            acis: self.acis.iter().map(Uuid::to_string).collect(),
            acis_binary: self
                .acis
                .iter()
                .map(|aci| aci.as_bytes().to_vec())
                .collect(),
            group_ids: self
                .group_master_keys
                .iter()
                .map(|key| {
                    GroupSecretParams::derive_from_master_key(
                        GroupMasterKey::new(*key),
                    )
                    .get_group_identifier()
                    .to_vec()
                })
                .collect(),
        }
    }
}

/// Typed views of an [`AccountRecord`].
pub trait AccountRecordExt {
    fn phone_number_sharing(&self) -> PhoneNumberSharingMode;
    /// Whether people who have the number can find the account.
    fn discoverable_by_phone_number(&self) -> bool;
    /// `(entropy, server id)` of the username link, when complete.
    fn username_link_parts(&self) -> Option<([u8; 32], Uuid)>;
}

impl AccountRecordExt for AccountRecord {
    fn phone_number_sharing(&self) -> PhoneNumberSharingMode {
        PhoneNumberSharingMode::try_from(self.phone_number_sharing_mode)
            .unwrap_or(PhoneNumberSharingMode::Unknown)
    }

    fn discoverable_by_phone_number(&self) -> bool {
        !self.unlisted_phone_number
    }

    fn username_link_parts(&self) -> Option<([u8; 32], Uuid)> {
        let link = self.username_link.as_ref()?;
        Some((
            link.entropy.as_slice().try_into().ok()?,
            Uuid::from_slice(&link.server_id).ok()?,
        ))
    }
}

/// Builds the username link stored in the [`AccountRecord`].
pub fn username_link_record(
    entropy: [u8; 32],
    server_id: Uuid,
) -> account_record::UsernameLink {
    account_record::UsernameLink {
        entropy: entropy.to_vec(),
        server_id: server_id.as_bytes().to_vec(),
        color: account_record::username_link::Color::Unknown.into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::proto::{contact_record, StorageItem};
    use crate::storage_service::StorageService;

    const ACI_X: Uuid = uuid::uuid!("3c1f0e53-5d8a-4a85-9e0c-6b1b1f3c2a01");
    const ACI_Y: Uuid = uuid::uuid!("9d0652a3-dcc3-4d11-975f-74d61598733f");
    const ACI_Z: Uuid = uuid::uuid!("00000000-1111-2222-3333-444444444444");
    const GROUP_KEY: [u8; 32] = [0x11; 32];

    fn rng() -> rand::rngs::StdRng {
        use rand::SeedableRng;
        rand::rngs::StdRng::seed_from_u64(7)
    }

    fn identifier(id: &[u8], kind: StorageRecordType) -> manifest_record::Identifier {
        manifest_record::Identifier {
            raw: id.to_vec(),
            r#type: kind.into(),
        }
    }

    /// A contact record plaintext with an extra field (number 99) this crate
    /// doesn't know about.
    fn contact_plaintext(record: &ContactRecord) -> Vec<u8> {
        let mut inner = record.encode_to_vec();
        wire::write_varint(99 << 3, &mut inner);
        wire::write_varint(42, &mut inner);
        wire::encode_length_delimited(CONTACT_FIELD, &inner)
    }

    fn record_plaintext(record: storage_record::Record) -> Vec<u8> {
        StorageRecord {
            record: Some(record),
        }
        .encode_to_vec()
    }

    /// Manifest v5 with contact X (id 1), group (id 2), account (id 3) and an
    /// unread story list (id 4).
    fn sample_state() -> StorageState {
        let manifest = ManifestRecord {
            version: 5,
            source_device: 1,
            identifiers: vec![
                identifier(&[1; 16], StorageRecordType::Contact),
                identifier(&[2; 16], StorageRecordType::Groupv2),
                identifier(&[3; 16], StorageRecordType::Account),
                identifier(&[4; 16], StorageRecordType::StoryDistributionList),
            ],
            record_ikm: vec![9; 32],
        };
        let mut state = StorageState::new(manifest);
        let contact = ContactRecord {
            aci: ACI_X.to_string(),
            e164: "+15550000001".into(),
            given_name: "Xavier".into(),
            system_given_name: "Xav".into(),
            whitelisted: true,
            ..Default::default()
        };
        state
            .insert_plaintext(vec![1; 16], contact_plaintext(&contact))
            .unwrap();
        state
            .insert_plaintext(
                vec![2; 16],
                record_plaintext(storage_record::Record::GroupV2(
                    GroupV2Record {
                        master_key: GROUP_KEY.to_vec(),
                        ..Default::default()
                    },
                )),
            )
            .unwrap();
        state
            .insert_plaintext(
                vec![3; 16],
                record_plaintext(storage_record::Record::Account(
                    AccountRecord {
                        read_receipts: true,
                        username: "corvus.42".into(),
                        ..Default::default()
                    },
                )),
            )
            .unwrap();
        state
    }

    fn decode_contact(plaintext: &[u8]) -> ContactRecord {
        match StorageRecord::decode(plaintext).unwrap().record {
            Some(storage_record::Record::Contact(c)) => c,
            other => panic!("not a contact: {other:?}"),
        }
    }

    fn block_x() -> StorageChange {
        StorageChange::Contact {
            target: ContactTarget::aci(ACI_X),
            patch: ContactPatch {
                blocked: Some(true),
                whitelisted: Some(false),
                ..Default::default()
            },
        }
    }

    #[test]
    fn views() {
        let state = sample_state();
        assert_eq!(state.missing_ids(), vec![vec![4; 16]]);
        assert_eq!(state.contacts().count(), 1);
        assert_eq!(state.groups_v2().count(), 1);
        assert_eq!(state.account().unwrap().username, "corvus.42");
        let by_phone = ContactTarget {
            e164: Some("+15550000001".into()),
            ..Default::default()
        };
        assert_eq!(state.contact(&by_phone).unwrap().given_name, "Xavier");
        // A different ACI never matches, even with the same number.
        let other = ContactTarget {
            aci: Some(ACI_Y),
            e164: Some("+15550000001".into()),
            ..Default::default()
        };
        assert!(state.contact(&other).is_none());
        assert!(state.group_v2(&GROUP_KEY).is_some());
    }

    #[test]
    fn modify_contact_replaces_record_and_keeps_unknown_fields() {
        let state = sample_state();
        let pending = state
            .plan_write(&[block_x()], 3, &mut rng())
            .unwrap()
            .expect("a change");

        assert_eq!(pending.manifest.version, 6);
        assert_eq!(pending.manifest.source_device, 3);
        assert_eq!(pending.manifest.record_ikm, vec![9; 32]);
        assert_eq!(pending.deletes, vec![vec![1; 16]]);
        assert_eq!(pending.inserts.len(), 1);
        let (new_id, plaintext) = &pending.inserts[0];
        assert_eq!(new_id.len(), STORAGE_ID_LEN);
        assert_ne!(new_id, &vec![1u8; 16]);

        // Untouched records (including the unread one) stay listed.
        let ids: Vec<_> =
            pending.manifest.identifiers.iter().map(|i| &i.raw).collect();
        assert_eq!(ids.len(), 4);
        assert!(ids.contains(&&vec![4u8; 16]));
        assert!(!ids.contains(&&vec![1u8; 16]));
        assert!(ids.contains(&new_id));

        let contact = decode_contact(plaintext);
        assert!(contact.blocked);
        assert!(!contact.whitelisted);
        assert_eq!(contact.given_name, "Xavier");
        let inner =
            wire::length_delimited(plaintext, CONTACT_FIELD).unwrap().unwrap();
        assert_eq!(
            wire::unknown_fields(inner, wire::CONTACT_RECORD_FIELDS).unwrap(),
            [0x98, 0x06, 42]
        );

        let after = state.apply_write(&pending).unwrap();
        assert_eq!(after.version(), 6);
        assert!(after.contact(&ContactTarget::aci(ACI_X)).unwrap().blocked);
        assert_eq!(after.blocked().acis, vec![ACI_X]);
    }

    #[test]
    fn unchanged_records_are_not_written() {
        let state = sample_state();
        let noop = StorageChange::Account(AccountPatch {
            read_receipts: Some(true),
            ..Default::default()
        });
        assert!(state.plan_write(&[noop], 3, &mut rng()).unwrap().is_none());
    }

    #[test]
    fn missing_contact_and_group_are_created() {
        let state = sample_state();
        let changes = [
            StorageChange::Contact {
                target: ContactTarget {
                    aci: Some(ACI_Y),
                    e164: Some("+15550000002".into()),
                    ..Default::default()
                },
                patch: ContactPatch {
                    nickname_given_name: Some("Why".into()),
                    nickname_family_name: Some("".into()),
                    note: Some("met at the conference".into()),
                    ..Default::default()
                },
            },
            StorageChange::GroupV2 {
                master_key: vec![0x22; 32],
                patch: GroupV2Patch {
                    blocked: Some(true),
                    ..Default::default()
                },
            },
        ];
        let pending =
            state.plan_write(&changes, 3, &mut rng()).unwrap().unwrap();
        assert!(pending.deletes.is_empty());
        assert_eq!(pending.inserts.len(), 2);
        assert_eq!(pending.manifest.identifiers.len(), 6);

        let after = state.apply_write(&pending).unwrap();
        let y = after.contact(&ContactTarget::aci(ACI_Y)).unwrap();
        assert_eq!(y.aci, ACI_Y.to_string());
        assert_eq!(y.aci_binary, ACI_Y.as_bytes());
        assert_eq!(y.e164, "+15550000002");
        assert_eq!(y.nickname_parts(), Some(("Why", "")));
        assert_eq!(y.note, "met at the conference");
        assert_eq!(after.blocked().group_master_keys, vec![[0x22; 32]]);
    }

    #[test]
    fn repeated_changes_to_one_record_make_one_insert() {
        let state = sample_state();
        let rename = StorageChange::Contact {
            target: ContactTarget::aci(ACI_X),
            patch: ContactPatch {
                note: Some("note".into()),
                ..Default::default()
            },
        };
        let pending = state
            .plan_write(&[block_x(), rename], 3, &mut rng())
            .unwrap()
            .unwrap();
        assert_eq!(pending.inserts.len(), 1);
        assert_eq!(pending.deletes, vec![vec![1; 16]]);
        let contact = decode_contact(&pending.inserts[0].1);
        assert!(contact.blocked);
        assert_eq!(contact.note, "note");
    }

    #[test]
    fn clearing_nickname_removes_it() {
        let mut record = ContactRecord {
            nickname: Some(contact_record::Name {
                given: "A".into(),
                family: "B".into(),
            }),
            ..Default::default()
        };
        ContactPatch {
            nickname_given_name: Some(String::new()),
            nickname_family_name: Some(String::new()),
            ..Default::default()
        }
        .apply(&mut record);
        assert_eq!(record.nickname, None);
    }

    /// After a 409 the local changes are re-planned on the newer remote
    /// manifest: remote edits survive, local edits are applied on top.
    #[test]
    fn conflict_merge_reapplies_changes_on_remote_state() {
        let local = sample_state();

        // Meanwhile the phone gave X a nickname (new id 7), added Y (id 8)
        // and wrote manifest v7.
        let mut remote_manifest = local.manifest().clone();
        remote_manifest.version = 7;
        remote_manifest.identifiers.retain(|i| i.raw != vec![1; 16]);
        remote_manifest
            .identifiers
            .push(identifier(&[7; 16], StorageRecordType::Contact));
        remote_manifest
            .identifiers
            .push(identifier(&[8; 16], StorageRecordType::Contact));
        let mut remote = local.clone().rebase(remote_manifest);
        assert_eq!(remote.missing_ids().len(), 3);
        let x_remote = ContactRecord {
            aci_binary: ACI_X.as_bytes().to_vec(),
            given_name: "Xavier".into(),
            nickname: Some(contact_record::Name {
                given: "Ex".into(),
                family: String::new(),
            }),
            whitelisted: true,
            ..Default::default()
        };
        remote
            .insert_plaintext(vec![7; 16], contact_plaintext(&x_remote))
            .unwrap();
        remote
            .insert_plaintext(
                vec![8; 16],
                record_plaintext(storage_record::Record::Contact(
                    ContactRecord {
                        aci: ACI_Z.to_string(),
                        ..Default::default()
                    },
                )),
            )
            .unwrap();

        let pending = remote
            .plan_write(&[block_x()], 3, &mut rng())
            .unwrap()
            .unwrap();
        assert_eq!(pending.manifest.version, 8);
        assert_eq!(pending.deletes, vec![vec![7; 16]]);
        let merged = decode_contact(&pending.inserts[0].1);
        assert!(merged.blocked);
        assert!(!merged.whitelisted);
        assert_eq!(merged.nickname_parts(), Some(("Ex", "")));
        assert_eq!(merged.aci_uuid(), Some(ACI_X));

        let after = remote.apply_write(&pending).unwrap();
        assert!(after.contact(&ContactTarget::aci(ACI_Z)).is_some());
        assert_eq!(after.contacts().count(), 2);
    }

    #[test]
    fn persistence_round_trip() {
        let state = sample_state();
        let restored = StorageState::from_bytes(&state.to_bytes()).unwrap();
        assert_eq!(restored, state);
        assert!(StorageState::from_bytes(&[0xff, 0xff]).is_err());
    }

    #[test]
    fn rebase_keeps_only_listed_records() {
        let state = sample_state();
        let mut manifest = state.manifest().clone();
        manifest.version = 6;
        manifest.identifiers.remove(0);
        let rebased = state.rebase(manifest);
        assert_eq!(rebased.contacts().count(), 0);
        assert_eq!(rebased.records().count(), 2);
        assert_eq!(rebased.missing_ids(), vec![vec![4; 16]]);
    }

    #[test]
    fn item_encryption_round_trip_and_compatibility() {
        let key = StorageServiceKey { inner: [5; 32] };
        let state = sample_state();
        let record = state.records().next().unwrap();
        for ikm in [None, state.record_ikm()] {
            let item = StorageService::encrypt_item_plaintext(
                &key,
                record.id.clone(),
                record.plaintext(),
                ikm,
            );
            assert_eq!(
                StorageService::decrypt_item_plaintext(&key, &item, ikm)
                    .unwrap(),
                record.plaintext()
            );
            // Readable by the record-level API too.
            assert_eq!(
                StorageService::decrypt_item(&key, &item, ikm).unwrap(),
                record.record
            );
        }
        let item = StorageService::encrypt_item(
            &key,
            vec![1; 16],
            &record.record,
            state.record_ikm(),
        );
        let wrong_ikm = StorageService::decrypt_item_plaintext(
            &key,
            &StorageItem {
                key: item.key.clone(),
                value: item.value.clone(),
            },
            None,
        );
        assert!(matches!(wrong_ikm, Err(StorageServiceError::Invalid)));
    }

    #[test]
    fn storage_key_from_account_entropy_pool() {
        let aep: AccountEntropyPool =
            "abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz01"
                .parse()
                .unwrap();
        let master_key = MasterKey::from_account_entropy_pool(&aep);
        assert_eq!(master_key.inner, aep.derive_svr_key());
        assert_eq!(
            StorageServiceKey::from_account_entropy_pool(&aep),
            StorageServiceKey::from_master_key(&master_key)
        );
    }

    #[test]
    fn blocked_sync_message_uses_group_identifiers() {
        let blocked = BlockedList {
            acis: vec![ACI_X],
            e164s: vec!["+15550000001".into()],
            group_master_keys: vec![GROUP_KEY],
        };
        let message = blocked.to_sync_message();
        assert_eq!(message.acis, vec![ACI_X.to_string()]);
        assert_eq!(message.acis_binary, vec![ACI_X.as_bytes().to_vec()]);
        assert_eq!(message.numbers, vec!["+15550000001".to_string()]);
        let expected = GroupSecretParams::derive_from_master_key(
            GroupMasterKey::new(GROUP_KEY),
        )
        .get_group_identifier();
        assert_eq!(message.group_ids, vec![expected.to_vec()]);
    }

    #[test]
    fn account_views() {
        let entropy = [3u8; 32];
        let record = AccountRecord {
            phone_number_sharing_mode: PhoneNumberSharingMode::Nobody.into(),
            unlisted_phone_number: true,
            username_link: Some(username_link_record(entropy, ACI_Y)),
            ..Default::default()
        };
        assert_eq!(record.phone_number_sharing(), PhoneNumberSharingMode::Nobody);
        assert!(!record.discoverable_by_phone_number());
        assert_eq!(record.username_link_parts(), Some((entropy, ACI_Y)));
    }
}
