//! Opening the presage SQLite store (SQLCipher) without message history, plus the small amount
//! of local state presage does not model, kept in the store's `corvus_kv` table.

use std::path::Path;

use presage::libsignal_service::prelude::Uuid;
use presage_store_sqlite::{OnNewIdentity, SqliteConnectOptions, SqliteStore, SqliteStoreError};
use serde::{Deserialize, Serialize, de::DeserializeOwned};

/// A 64 hex character SQLCipher key (32 raw bytes).
#[derive(Clone)]
pub struct StoreKey(String);

impl StoreKey {
    pub fn parse(line: &str) -> Result<Self, String> {
        let key = line.trim();
        if key.len() != 64 || !key.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err("the store key must be 64 hex characters".into());
        }
        Ok(Self(key.to_ascii_lowercase()))
    }
}

impl std::fmt::Debug for StoreKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("StoreKey(…)")
    }
}

pub async fn open(path: &Path, key: Option<&StoreKey>) -> Result<SqliteStore, SqliteStoreError> {
    let mut options = SqliteConnectOptions::new()
        .filename(path)
        .create_if_missing(true)
        .foreign_keys(true);
    if let Some(StoreKey(hex)) = key {
        // Raw key: no passphrase derivation.
        options = options.pragma("key", format!("\"x'{hex}'\""));
    }
    let store = SqliteStore::open_with_options(options, OnNewIdentity::Trust)
        .await?
        .without_message_history();
    Ok(store)
}

/// Settings Corvus keeps per contact that presage has no column for.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct LocalContact {
    pub blocked: bool,
    pub hidden: bool,
    pub archived: bool,
    pub nick_given_name: String,
    pub nick_family_name: String,
    pub note: String,
    pub given_name: String,
    pub family_name: String,
}

/// What we know about a peer's identity key.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct IdentityRecord {
    /// base64 of the serialized identity key this record is about
    pub key: String,
    pub added: u64,
    /// UNTRUSTED, TRUSTED_UNVERIFIED or TRUSTED_VERIFIED
    pub level: String,
}

pub struct Local<'a> {
    store: &'a SqliteStore,
}

impl<'a> Local<'a> {
    pub fn new(store: &'a SqliteStore) -> Self {
        Self { store }
    }

    async fn get<T: DeserializeOwned + Default>(&self, key: &str) -> T {
        match self.store.kv_get(key).await {
            Ok(Some(bytes)) => serde_json::from_slice(&bytes).unwrap_or_default(),
            _ => T::default(),
        }
    }

    async fn set<T: Serialize>(&self, key: &str, value: &T) -> Result<(), SqliteStoreError> {
        self.store.kv_set(key, &serde_json::to_vec(value)?).await
    }

    pub async fn contact(&self, uuid: &Uuid) -> LocalContact {
        self.get(&format!("contact:{uuid}")).await
    }

    pub async fn set_contact(&self, uuid: &Uuid, c: &LocalContact) -> Result<(), SqliteStoreError> {
        if *c == LocalContact::default() {
            return self.store.kv_delete(&format!("contact:{uuid}")).await;
        }
        self.set(&format!("contact:{uuid}"), c).await
    }

    pub async fn update_contact(
        &self,
        uuid: &Uuid,
        f: impl FnOnce(&mut LocalContact),
    ) -> Result<(), SqliteStoreError> {
        let mut c = self.contact(uuid).await;
        f(&mut c);
        self.set_contact(uuid, &c).await
    }

    pub async fn all_contacts(&self) -> Vec<(Uuid, LocalContact)> {
        self.store
            .kv_list("contact:")
            .await
            .unwrap_or_default()
            .into_iter()
            .filter_map(|(k, v)| {
                let uuid = Uuid::parse_str(k.strip_prefix("contact:")?).ok()?;
                Some((uuid, serde_json::from_slice(&v).ok()?))
            })
            .collect()
    }

    pub async fn group_blocked(&self, group_id: &str) -> bool {
        self.store
            .kv_get(&format!("group-blocked:{group_id}"))
            .await
            .ok()
            .flatten()
            .is_some()
    }

    pub async fn set_group_blocked(&self, group_id: &str, blocked: bool) -> Result<(), SqliteStoreError> {
        let key = format!("group-blocked:{group_id}");
        if blocked {
            self.store.kv_set(&key, b"1").await
        } else {
            self.store.kv_delete(&key).await
        }
    }

    pub async fn blocked_groups(&self) -> Vec<String> {
        self.store
            .kv_list("group-blocked:")
            .await
            .unwrap_or_default()
            .into_iter()
            .filter_map(|(k, _)| k.strip_prefix("group-blocked:").map(str::to_owned))
            .collect()
    }

    /// Numbers blocked on another device that we could not map to an account.
    pub async fn blocked_numbers(&self) -> Vec<String> {
        self.get("blocked-numbers").await
    }

    pub async fn set_blocked_numbers(&self, numbers: &[String]) -> Result<(), SqliteStoreError> {
        self.set("blocked-numbers", &numbers).await
    }

    pub async fn identity(&self, uuid: &Uuid) -> Option<IdentityRecord> {
        let r: IdentityRecord = self.get(&format!("identity:{uuid}")).await;
        (!r.key.is_empty()).then_some(r)
    }

    pub async fn set_identity(&self, uuid: &Uuid, r: &IdentityRecord) -> Result<(), SqliteStoreError> {
        self.set(&format!("identity:{uuid}"), r).await
    }

    /// Our username as last set or synced (Corvus shows it in the profile editor).
    pub async fn own_username(&self) -> Option<String> {
        let u: String = self.get("own-username").await;
        (!u.is_empty()).then_some(u)
    }

    pub async fn set_own_username(&self, username: Option<&str>) -> Result<(), SqliteStoreError> {
        match username {
            Some(u) => self.set("own-username", &u).await,
            None => self.store.kv_delete("own-username").await,
        }
    }

    /// Small JSON values without their own accessor (settings mirrors and the like).
    pub async fn value<T: DeserializeOwned + Default>(&self, key: &str) -> T {
        self.get(&format!("value:{key}")).await
    }

    pub async fn set_value<T: Serialize>(&self, key: &str, value: &T) -> Result<(), SqliteStoreError> {
        self.set(&format!("value:{key}"), value).await
    }

    pub async fn sticker_key(&self, pack_id_hex: &str) -> Option<Vec<u8>> {
        self.store
            .kv_get(&format!("sticker-key:{}", pack_id_hex.to_ascii_lowercase()))
            .await
            .ok()
            .flatten()
    }

    pub async fn set_sticker_key(&self, pack_id_hex: &str, key: &[u8]) -> Result<(), SqliteStoreError> {
        self.store
            .kv_set(&format!("sticker-key:{}", pack_id_hex.to_ascii_lowercase()), key)
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn key_validation() {
        assert!(StoreKey::parse(&"a".repeat(64)).is_ok());
        assert!(StoreKey::parse(&format!("{}\n", "AB".repeat(32))).is_ok());
        assert!(StoreKey::parse("short").is_err());
        assert!(StoreKey::parse(&"g".repeat(64)).is_err());
        assert_eq!(format!("{:?}", StoreKey::parse(&"a".repeat(64)).unwrap()), "StoreKey(…)");
    }

    #[tokio::test(flavor = "current_thread")]
    async fn encrypted_store_roundtrip_and_local_state() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("store.db");
        let key = StoreKey::parse(&"0f".repeat(32)).unwrap();
        let store = open(&path, Some(&key)).await.unwrap();
        let local = Local::new(&store);
        let uuid = Uuid::from_u128(42);
        local
            .update_contact(&uuid, |c| {
                c.blocked = true;
                c.note = "n".into();
            })
            .await
            .unwrap();
        local.set_group_blocked("abc=", true).await.unwrap();
        store.close().await;

        // not readable without the key
        let plain = std::fs::read(&path).unwrap();
        assert!(!plain.starts_with(b"SQLite format 3"));
        assert!(open(&path, None).await.is_err());
        let wrong = StoreKey::parse(&"1e".repeat(32)).unwrap();
        assert!(open(&path, Some(&wrong)).await.is_err());

        let store = open(&path, Some(&key)).await.unwrap();
        let local = Local::new(&store);
        let c = local.contact(&uuid).await;
        assert!(c.blocked);
        assert_eq!(c.note, "n");
        assert_eq!(local.all_contacts().await.len(), 1);
        assert!(local.group_blocked("abc=").await);
        assert_eq!(local.blocked_groups().await, vec!["abc=".to_string()]);
        local.set_contact(&uuid, &LocalContact::default()).await.unwrap();
        assert!(local.all_contacts().await.is_empty());
        store.close().await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn messages_are_not_persisted() {
        use presage::libsignal_service::content::{Content, ContentBody, Metadata};
        use presage::libsignal_service::protocol::{Aci, ServiceId};
        use presage::proto::DataMessage;
        use presage::store::{ContentsStore, Thread};

        let tmp = tempfile::tempdir().unwrap();
        let store = open(&tmp.path().join("s.db"), None).await.unwrap();
        let sender: ServiceId = Aci::from(Uuid::from_u128(7)).into();
        let now = chrono::Utc::now();
        let content = Content {
            metadata: Metadata {
                sender,
                destination: sender,
                sender_device: 1.try_into().unwrap(),
                server_guid: None,
                client_timestamp: now,
                server_timestamp: now,
                needs_receipt: false,
                unidentified_sender: false,
                was_plaintext: false,
                pni_verified: None,
            },
            body: ContentBody::DataMessage(DataMessage {
                body: Some("secret".into()),
                timestamp: Some(now.timestamp_millis() as u64),
                ..Default::default()
            }),
        };
        let thread = Thread::Contact(sender);
        store.save_message(&thread, content).await.unwrap();
        let count = store.messages(&thread, ..).await.unwrap().count();
        assert_eq!(count, 0);
        store.close().await;
    }
}
