use std::str::FromStr;

use presage::{
    libsignal_service::{
        libsignal_account_keys::AccountEntropyPool, prelude::MasterKey, protocol::SenderCertificate,
    },
    store::{StateStore, Store},
};
use protocol::{IdentityType, SqliteProtocolStore};
use sqlx::{
    SqlitePool, query, query_scalar,
    sqlite::{SqliteJournalMode, SqlitePoolOptions, SqliteSynchronous},
};

mod content;
mod data;
mod error;
mod group_extras;
mod protocol;
mod storage_service;

pub use error::SqliteStoreError;
pub use presage::model::identity::OnNewIdentity;
pub use sqlx::sqlite::SqliteConnectOptions;

use crate::error::SqlxErrorExt;

#[derive(Debug, Clone)]
pub struct SqliteStore {
    pub(crate) db: SqlitePool,
    pub(crate) trust_new_identities: OnNewIdentity,
    /// Corvus patch: when false, message contents are never written to `thread_messages`.
    pub(crate) persist_messages: bool,
}

impl SqliteStore {
    /// Begins a transaction that writes, taking the write lock at once. A deferred transaction
    /// that reads before it writes fails with `SQLITE_BUSY`, which no busy timeout waits out,
    /// when another connection to the database writes in between.
    pub(crate) async fn begin_write(
        &self,
    ) -> Result<sqlx::Transaction<'static, sqlx::Sqlite>, sqlx::Error> {
        self.db.begin_with("BEGIN IMMEDIATE").await
    }

    pub async fn open(
        url: &str,
        trust_new_identities: OnNewIdentity,
    ) -> Result<Self, SqliteStoreError> {
        Self::open_with_passphrase(url, None, trust_new_identities).await
    }

    pub async fn open_with_passphrase(
        url: &str,
        passphrase: Option<&str>,
        trust_new_identities: OnNewIdentity,
    ) -> Result<Self, SqliteStoreError> {
        // Escape the passphrase.
        let passphrase = passphrase.map(|p| p.replace("'", "''"));

        let options: SqliteConnectOptions = url.parse()?;
        let options = options.create_if_missing(true).foreign_keys(true);
        let options = if let Some(passphrase) = &passphrase {
            options.pragma("key", format!("'{passphrase}'"))
        } else {
            options
        };
        Self::open_with_options(options.clone(), trust_new_identities.clone()).await
    }

    pub async fn open_with_options(
        options: SqliteConnectOptions,
        trust_new_identities: OnNewIdentity,
    ) -> Result<Self, SqliteStoreError> {
        let options = options
            .journal_mode(SqliteJournalMode::Wal)
            .synchronous(SqliteSynchronous::Full);
        // Each connection carries its own page cache; sqlx's default of 10 is more than we need.
        // Corvus patch: connections are kept open. Opening one runs SQLCipher's key derivation (about
        // a second); with sqlx's idle timeout and lifetime every request after a quiet spell (and
        // every message after the Mac wakes) waited for that.
        let db = SqlitePoolOptions::new()
            .max_connections(3)
            .min_connections(3)
            .idle_timeout(None)
            .max_lifetime(None)
            .connect_with(options)
            .await?;

        sqlx::migrate!().run(&db).await?;
        // Corvus patch: a key-value table for state presage does not model (local contact
        // settings, trust levels, group fields). Created outside the migrations so upstream
        // migrations stay in order.
        sqlx::query(
            "CREATE TABLE IF NOT EXISTS corvus_kv (key TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL)",
        )
        .execute(&db)
        .await?;
        Ok(Self {
            db,
            trust_new_identities,
            persist_messages: true,
        })
    }

    /// Corvus patch: never store message contents (the client keeps its own history). Protocol
    /// state, contacts, groups, profiles and stickers are still stored.
    pub fn without_message_history(mut self) -> Self {
        self.persist_messages = false;
        self
    }

    /// Corvus patch: the installed sticker packs as (id, title, author, `[[sticker id, emoji], …]` as
    /// JSON), read in SQLite. The manifests also hold every sticker image (as JSON number arrays):
    /// reading them whole took a second and more.
    pub async fn sticker_pack_summaries(
        &self,
    ) -> Result<Vec<(Vec<u8>, String, String, String)>, SqliteStoreError> {
        let rows: Vec<(Vec<u8>, Option<String>, Option<String>, Option<String>)> = sqlx::query_as(
            "SELECT sticker_packs.id, json_extract(manifest, '$.title'), json_extract(manifest, '$.author'), \
             (SELECT json_group_array(json_array(json_extract(s.value, '$.id'), json_extract(s.value, '$.emoji'))) \
              FROM json_each(manifest, '$.stickers') AS s) \
             FROM sticker_packs",
        )
        .fetch_all(&self.db)
        .await?;
        Ok(rows
            .into_iter()
            .map(|(id, title, author, stickers)| {
                (id, title.unwrap_or_default(), author.unwrap_or_default(), stickers.unwrap_or_else(|| "[]".into()))
            })
            .collect())
    }

    /// Corvus patch: [Self::sticker_pack_summaries] for one pack (None: not installed).
    pub async fn sticker_pack_summary(
        &self,
        id: &[u8],
    ) -> Result<Option<(String, String, String)>, SqliteStoreError> {
        let row: Option<(Option<String>, Option<String>, Option<String>)> = sqlx::query_as(
            "SELECT json_extract(manifest, '$.title'), json_extract(manifest, '$.author'), \
             (SELECT json_group_array(json_array(json_extract(s.value, '$.id'), json_extract(s.value, '$.emoji'))) \
              FROM json_each(manifest, '$.stickers') AS s) \
             FROM sticker_packs WHERE id = ?",
        )
        .bind(id)
        .fetch_optional(&self.db)
        .await?;
        Ok(row.map(|(title, author, stickers)| {
            (title.unwrap_or_default(), author.unwrap_or_default(), stickers.unwrap_or_else(|| "[]".into()))
        }))
    }

    /// Corvus patch: the ids of the installed sticker packs (cheap: no manifest is read).
    pub async fn sticker_pack_ids(&self) -> Result<Vec<Vec<u8>>, SqliteStoreError> {
        Ok(query_scalar("SELECT id FROM sticker_packs ORDER BY id").fetch_all(&self.db).await?)
    }

    /// Corvus patch: the key of an installed sticker pack, without reading its manifest.
    pub async fn sticker_pack_key(&self, id: &[u8]) -> Result<Option<Vec<u8>>, SqliteStoreError> {
        Ok(query_scalar("SELECT key FROM sticker_packs WHERE id = ?")
            .bind(id)
            .fetch_optional(&self.db)
            .await?)
    }

    /// Corvus patch: the emoji of one sticker of an installed pack (outer None: no such pack).
    pub async fn sticker_emoji(
        &self,
        pack: &[u8],
        sticker: u32,
    ) -> Result<Option<Option<String>>, SqliteStoreError> {
        if self.sticker_pack_key(pack).await?.is_none() {
            return Ok(None);
        }
        let emoji: Option<Option<String>> = query_scalar(
            "SELECT json_extract(s.value, '$.emoji') FROM sticker_packs, json_each(manifest, '$.stickers') AS s \
             WHERE sticker_packs.id = ? AND json_extract(s.value, '$.id') = ?",
        )
        .bind(pack)
        .bind(sticker as i64)
        .fetch_optional(&self.db)
        .await?;
        Ok(Some(emoji.flatten()))
    }

    /// Corvus patch: reads a value from the `corvus_kv` table.
    pub async fn kv_get(&self, key: &str) -> Result<Option<Vec<u8>>, SqliteStoreError> {
        Ok(sqlx::query_scalar("SELECT value FROM corvus_kv WHERE key = ?")
            .bind(key)
            .fetch_optional(&self.db)
            .await?)
    }

    /// Corvus patch: writes a value to the `corvus_kv` table.
    pub async fn kv_set(&self, key: &str, value: &[u8]) -> Result<(), SqliteStoreError> {
        sqlx::query("INSERT OR REPLACE INTO corvus_kv (key, value) VALUES (?, ?)")
            .bind(key)
            .bind(value)
            .execute(&self.db)
            .await?;
        Ok(())
    }

    /// Corvus patch: deletes a value from the `corvus_kv` table.
    pub async fn kv_delete(&self, key: &str) -> Result<(), SqliteStoreError> {
        sqlx::query("DELETE FROM corvus_kv WHERE key = ?")
            .bind(key)
            .execute(&self.db)
            .await?;
        Ok(())
    }

    /// Corvus patch: all `corvus_kv` entries whose key starts with `prefix`.
    pub async fn kv_list(&self, prefix: &str) -> Result<Vec<(String, Vec<u8>)>, SqliteStoreError> {
        let rows: Vec<(String, Vec<u8>)> =
            sqlx::query_as("SELECT key, value FROM corvus_kv WHERE substr(key, 1, ?) = ?")
                .bind(prefix.len() as i64)
                .bind(prefix)
                .fetch_all(&self.db)
                .await?;
        Ok(rows)
    }

    /// Closes the pool, waiting for all connections to close.
    /// Call before exit: SQLCipher's atexit cleanup races connections still closing.
    pub async fn close(&self) {
        self.db.close().await;
    }
}

impl Store for SqliteStore {
    type Error = SqliteStoreError;

    type AciStore = SqliteProtocolStore;

    type PniStore = SqliteProtocolStore;

    async fn clear(&mut self) -> Result<(), SqliteStoreError> {
        query!("DELETE FROM kv").execute(&self.db).await?;
        Ok(())
    }

    fn aci_protocol_store(&self) -> Self::AciStore {
        SqliteProtocolStore {
            store: self.clone(),
            identity: IdentityType::Aci,
        }
    }

    fn pni_protocol_store(&self) -> Self::PniStore {
        SqliteProtocolStore {
            store: self.clone(),
            identity: IdentityType::Pni,
        }
    }
}

impl StateStore for SqliteStore {
    type StateStoreError = SqliteStoreError;

    async fn load_registration_data(
        &self,
    ) -> Result<Option<presage::manager::RegistrationData>, Self::StateStoreError> {
        query_scalar!("SELECT value FROM kv WHERE key = 'registration'")
            .fetch_optional(&self.db)
            .await?
            .map(|value| serde_json::from_slice(&value))
            .transpose()
            .map_err(From::from)
    }

    async fn save_registration_data(
        &mut self,
        state: &presage::manager::RegistrationData,
    ) -> Result<(), Self::StateStoreError> {
        let value = serde_json::to_string(state)?;
        query!(
            "INSERT OR REPLACE INTO kv (key, value) VALUES ('registration', ?)",
            value
        )
        .execute(&self.db)
        .await?;
        Ok(())
    }

    async fn is_registered(&self) -> bool {
        self.load_registration_data().await.ok().flatten().is_some()
    }

    async fn clear_registration(&mut self) -> Result<(), Self::StateStoreError> {
        let mut transaction = self.begin_write().await.into_protocol_error()?;
        query!("DELETE FROM kv WHERE key = 'registration'")
            .execute(&mut *transaction)
            .await?;
        query!("DELETE FROM sessions")
            .execute(&mut *transaction)
            .await?;
        query!("DELETE FROM identities")
            .execute(&mut *transaction)
            .await?;
        query!("DELETE FROM pre_keys")
            .execute(&mut *transaction)
            .await?;
        query!("DELETE FROM signed_pre_keys")
            .execute(&mut *transaction)
            .await?;
        query!("DELETE FROM kyber_pre_keys")
            .execute(&mut *transaction)
            .await?;
        query!("DELETE FROM sender_keys")
            .execute(&mut *transaction)
            .await?;
        transaction.commit().await.into_protocol_error()?;
        Ok(())
    }

    async fn set_aci_identity_key_pair(
        &self,
        key_pair: presage::libsignal_service::protocol::IdentityKeyPair,
    ) -> Result<(), Self::StateStoreError> {
        let key = IdentityType::Aci.identity_key_pair_key();
        let value = key_pair.serialize();
        query!(
            "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
            key,
            value
        )
        .execute(&self.db)
        .await?;
        Ok(())
    }

    async fn set_pni_identity_key_pair(
        &self,
        key_pair: presage::libsignal_service::protocol::IdentityKeyPair,
    ) -> Result<(), Self::StateStoreError> {
        let key = IdentityType::Pni.identity_key_pair_key();
        let value = key_pair.serialize();
        query!(
            "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
            key,
            value
        )
        .execute(&self.db)
        .await?;
        Ok(())
    }

    async fn sender_certificate(&self) -> Result<Option<SenderCertificate>, Self::StateStoreError> {
        query_scalar!("SELECT value FROM kv WHERE key = 'sender_certificate' LIMIT 1")
            .fetch_optional(&self.db)
            .await?
            .map(|value| SenderCertificate::deserialize(&value))
            .transpose()
            .map_err(From::from)
    }

    async fn save_sender_certificate(
        &self,
        certificate: &SenderCertificate,
    ) -> Result<(), Self::StateStoreError> {
        let value = certificate.serialized()?;
        query!(
            "INSERT OR REPLACE INTO kv (key, value) VALUES ('sender_certificate', ?)",
            value
        )
        .execute(&self.db)
        .await?;
        Ok(())
    }

    async fn fetch_master_key(&self) -> Result<Option<MasterKey>, Self::StateStoreError> {
        query_scalar!("SELECT value FROM kv WHERE key = 'master_key' LIMIT 1")
            .fetch_optional(&self.db)
            .await?
            .map(|value| MasterKey::from_slice(&value))
            .transpose()
            .map_err(|_| SqliteStoreError::InvalidFormat)
    }

    async fn store_master_key(
        &self,
        master_key: Option<&MasterKey>,
    ) -> Result<(), Self::StateStoreError> {
        let value = master_key.map(|k| &k.inner[..]);
        if let Some(value) = value {
            query!(
                "INSERT OR REPLACE INTO kv (key, value) VALUES ('master_key', ?)",
                value
            )
            .execute(&self.db)
            .await?;
        } else {
            query!("DELETE FROM kv WHERE key = 'master_key'")
                .execute(&self.db)
                .await?;
        }
        Ok(())
    }

    async fn fetch_account_entropy_pool(
        &self,
    ) -> Result<Option<AccountEntropyPool>, Self::StateStoreError> {
        query_scalar!("SELECT value FROM kv WHERE key = 'account_entropy_pool' LIMIT 1")
            .fetch_optional(&self.db)
            .await?
            .map(|value| {
                AccountEntropyPool::from_str(
                    str::from_utf8(&value).map_err(|_| SqliteStoreError::InvalidFormat)?,
                )
                .map_err(|_| SqliteStoreError::InvalidFormat)
            })
            .transpose()
            .map_err(|_| SqliteStoreError::InvalidFormat)
    }

    async fn store_account_entropy_pool(
        &self,
        aep: Option<&AccountEntropyPool>,
    ) -> Result<(), Self::StateStoreError> {
        let value = aep.map(|k| k.to_string().into_bytes());
        if let Some(value) = value {
            query!(
                "INSERT OR REPLACE INTO kv (key, value) VALUES ('account_entropy_pool', ?)",
                value
            )
            .execute(&self.db)
            .await?;
        } else {
            query!("DELETE FROM kv WHERE key = 'account_entropy_pool'")
                .execute(&self.db)
                .await?;
        }
        Ok(())
    }

    async fn storage_service_state(&self) -> Result<Option<Vec<u8>>, Self::StateStoreError> {
        self.load_storage_service_state().await
    }

    async fn save_storage_service_state(
        &self,
        state: Option<&[u8]>,
    ) -> Result<(), Self::StateStoreError> {
        self.write_storage_service_state(state).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn close_closes_the_pool() {
        let store = SqliteStore::open(":memory:", OnNewIdentity::Trust)
            .await
            .unwrap();
        let clone = store.clone();

        store.close().await;

        assert!(clone.db.is_closed());
    }
}

#[cfg(test)]
mod sticker_summary_tests {
    use presage::store::{ContentsStore, StickerPack, StickerPackManifest};
    use presage::model::identity::OnNewIdentity;

    use super::SqliteStore;

    #[tokio::test]
    async fn summaries_leave_the_images_out() -> Result<(), Box<dyn std::error::Error>> {
        let path = std::env::temp_dir().join(format!("presage-sticker-test-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let mut store = SqliteStore::open(path.to_str().unwrap(), OnNewIdentity::Trust).await?;
        let sticker = |id, emoji: Option<&str>| presage::store::Sticker {
            id,
            emoji: emoji.map(str::to_owned),
            content_type: Some("image/webp".into()),
            bytes: Some(vec![7; 1000]),
        };
        store
            .add_sticker_pack(&StickerPack {
                id: vec![1, 2, 3],
                key: vec![9; 32],
                manifest: StickerPackManifest {
                    title: "Cats".into(),
                    author: "Ann".into(),
                    cover: None,
                    stickers: vec![sticker(0, Some("🐱")), sticker(1, None)],
                },
            })
            .await?;
        let list = store.sticker_pack_summaries().await?;
        assert_eq!(list.len(), 1);
        let (id, title, author, stickers) = &list[0];
        assert_eq!((id.as_slice(), title.as_str(), author.as_str()), (&[1u8, 2, 3][..], "Cats", "Ann"));
        assert_eq!(stickers, r#"[[0,"🐱"],[1,null]]"#);
        assert_eq!(store.sticker_pack_key(&[1, 2, 3]).await?, Some(vec![9; 32]));
        assert_eq!(store.sticker_pack_key(&[4]).await?, None);
        assert_eq!(store.sticker_emoji(&[1, 2, 3], 0).await?, Some(Some("🐱".into())));
        assert_eq!(store.sticker_emoji(&[1, 2, 3], 1).await?, Some(None));
        assert_eq!(store.sticker_emoji(&[4], 0).await?, None);
        let _ = std::fs::remove_file(&path);
        Ok(())
    }
}
