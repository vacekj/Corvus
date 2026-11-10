//! Persisted Storage Service snapshot (`kv` row `storage_service_state`).

use sqlx::{query, query_scalar};

use crate::{SqliteStore, SqliteStoreError};

const KEY: &str = "storage_service_state";

impl SqliteStore {
    pub(crate) async fn load_storage_service_state(
        &self,
    ) -> Result<Option<Vec<u8>>, SqliteStoreError> {
        Ok(
            query_scalar::<_, Vec<u8>>("SELECT value FROM kv WHERE key = ? LIMIT 1")
                .bind(KEY)
                .fetch_optional(&self.db)
                .await?,
        )
    }

    pub(crate) async fn write_storage_service_state(
        &self,
        state: Option<&[u8]>,
    ) -> Result<(), SqliteStoreError> {
        match state {
            Some(state) => {
                query("INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)")
                    .bind(KEY)
                    .bind(state)
                    .execute(&self.db)
                    .await?;
            }
            None => {
                query("DELETE FROM kv WHERE key = ?")
                    .bind(KEY)
                    .execute(&self.db)
                    .await?;
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use presage::store::StateStore;

    use crate::{OnNewIdentity, SqliteStore};

    #[tokio::test]
    async fn storage_service_state_round_trip() {
        let store = SqliteStore::open(":memory:", OnNewIdentity::Trust)
            .await
            .unwrap();
        assert_eq!(store.storage_service_state().await.unwrap(), None);
        store
            .save_storage_service_state(Some(b"state v1"))
            .await
            .unwrap();
        store
            .save_storage_service_state(Some(b"state v2"))
            .await
            .unwrap();
        assert_eq!(
            store.storage_service_state().await.unwrap().as_deref(),
            Some(&b"state v2"[..])
        );
        store.save_storage_service_state(None).await.unwrap();
        assert_eq!(store.storage_service_state().await.unwrap(), None);
    }
}
