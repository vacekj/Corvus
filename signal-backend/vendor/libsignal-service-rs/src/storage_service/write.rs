//! Incremental reads into a [`StorageState`] and manifest writes with
//! conflict handling.

use prost::Message;
use reqwest::Method;

use crate::configuration::Endpoint;
use crate::master_key::StorageServiceKey;
use crate::proto::{ReadOperation, StorageItem, StorageItems, WriteOperation};
use crate::push_service::protobuf::ProtobufResponseExt;
use crate::push_service::{HttpAuthOverride, SignalServiceResponse};

use super::state::{PendingWrite, StorageChange, StorageState};
use super::{decrypt, encrypt, StorageService, StorageServiceError};

/// Ids per `PUT /v1/storage/read` (the server allows 5120).
const READ_BATCH: usize = 1000;

/// Outcome of [`StorageService::commit`].
#[derive(Debug)]
pub struct CommitOutcome {
    /// The state after the write (or the refreshed state if nothing changed).
    pub state: StorageState,
    /// Whether a new manifest version was written.
    pub written: bool,
}

impl StorageService {
    pub fn storage_key(&self) -> &StorageServiceKey {
        &self.storage_key
    }

    /// Brings `previous` up to date with the server, reading only records not
    /// already held. Without `previous`, reads everything. Records that fail to
    /// decrypt are skipped (they stay listed in the manifest).
    pub async fn fetch_state(
        &self,
        previous: Option<StorageState>,
    ) -> Result<StorageState, StorageServiceError> {
        let mut state = match previous {
            Some(previous) => {
                match self.manifest_if_changed(previous.version()).await? {
                    None => previous,
                    Some(manifest) => previous.rebase(manifest),
                }
            },
            None => StorageState::new(self.manifest().await?),
        };

        let missing = state.missing_ids();
        for batch in missing.chunks(READ_BATCH) {
            for item in self.read_raw_items(batch.to_vec()).await? {
                match Self::decrypt_item_plaintext(
                    &self.storage_key,
                    &item,
                    state.record_ikm(),
                ) {
                    Ok(plaintext) => {
                        if let Err(error) =
                            state.insert_plaintext(item.key, plaintext)
                        {
                            tracing::warn!(%error, "skipping undecodable storage record");
                        }
                    },
                    Err(error) => {
                        tracing::warn!(%error, "skipping undecryptable storage record")
                    },
                }
            }
        }
        Ok(state)
    }

    /// Fetches encrypted storage items by id.
    pub async fn read_raw_items(
        &self,
        keys: Vec<Vec<u8>>,
    ) -> Result<Vec<StorageItem>, StorageServiceError> {
        let body = ReadOperation { read_key: keys }.encode_to_vec();
        let items: StorageItems = self
            .service
            .request(
                Method::PUT,
                Endpoint::storage("/v1/storage/read"),
                HttpAuthOverride::Identified(self.credentials.clone()),
            )?
            .header("Content-Type", "application/x-protobuf")
            .body(body)
            .send()
            .await?
            .service_error_for_status()
            .await?
            .protobuf()
            .await?;
        Ok(items.items)
    }

    /// Uploads `pending` (`PUT /v1/storage`). A manifest version that is no
    /// longer the next one yields [`StorageServiceError::Conflict`].
    pub async fn write(
        &self,
        pending: &PendingWrite,
    ) -> Result<(), StorageServiceError> {
        let record_ikm = Some(pending.manifest.record_ikm.as_slice())
            .filter(|ikm| !ikm.is_empty());
        let operation = WriteOperation {
            manifest: Some(Self::encrypt_manifest(
                &self.storage_key,
                &pending.manifest,
            )),
            insert_item: pending
                .inserts
                .iter()
                .map(|(id, plaintext)| {
                    Self::encrypt_item_plaintext(
                        &self.storage_key,
                        id.clone(),
                        plaintext,
                        record_ikm,
                    )
                })
                .collect(),
            delete_key: pending.deletes.clone(),
            clear_all: false,
        };

        let response = self
            .service
            .request(
                Method::PUT,
                Endpoint::storage("/v1/storage"),
                HttpAuthOverride::Identified(self.credentials.clone()),
            )?
            .header("Content-Type", "application/x-protobuf")
            .body(operation.encode_to_vec())
            .send()
            .await?;
        if response.status() == reqwest::StatusCode::CONFLICT {
            return Err(StorageServiceError::Conflict);
        }
        response.service_error_for_status().await?;
        Ok(())
    }

    /// Applies `changes` and writes a new manifest version. On a version
    /// conflict the state is refreshed and the changes re-applied to it, up to
    /// `max_attempts` writes.
    pub async fn commit(
        &self,
        state: StorageState,
        changes: &[StorageChange],
        source_device: u32,
        max_attempts: usize,
    ) -> Result<CommitOutcome, StorageServiceError> {
        let mut state = state;
        for attempt in 1..=max_attempts.max(1) {
            let pending =
                state.plan_write(changes, source_device, &mut rand::rng())?;
            let Some(pending) = pending else {
                return Ok(CommitOutcome {
                    state,
                    written: false,
                });
            };
            match self.write(&pending).await {
                Ok(()) => {
                    return Ok(CommitOutcome {
                        state: state.apply_write(&pending)?,
                        written: true,
                    })
                },
                Err(StorageServiceError::Conflict) => {
                    tracing::info!(attempt, "storage manifest conflict, merging");
                    state = self.fetch_state(Some(state)).await?;
                },
                Err(error) => return Err(error),
            }
        }
        Err(StorageServiceError::Conflict)
    }

    /// Decrypts a [`StorageItem`] to its `StorageRecord` plaintext.
    pub fn decrypt_item_plaintext(
        storage_key: &StorageServiceKey,
        item: &StorageItem,
        record_ikm: Option<&[u8]>,
    ) -> Result<Vec<u8>, StorageServiceError> {
        let key = Self::item_key(storage_key, &item.key, record_ikm);
        decrypt(&key, &item.value)
    }

    /// Encrypts `StorageRecord` plaintext into a [`StorageItem`].
    pub fn encrypt_item_plaintext(
        storage_key: &StorageServiceKey,
        raw_id: Vec<u8>,
        plaintext: &[u8],
        record_ikm: Option<&[u8]>,
    ) -> StorageItem {
        let key = Self::item_key(storage_key, &raw_id, record_ikm);
        StorageItem {
            key: raw_id,
            value: encrypt(&key, plaintext),
        }
    }
}
