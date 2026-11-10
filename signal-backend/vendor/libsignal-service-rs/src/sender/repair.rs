//! Corvus: sending side of decryption-error recovery (see `crate::session_repair`).

use std::{collections::HashSet, time::SystemTime};

use base64::prelude::*;
use libsignal_protocol::{
    process_prekey_bundle, DecryptionErrorMessage, DeviceId, PlaintextContent,
    ProtocolAddress, ProtocolStore, SenderKeyStore, ServiceId,
};
use rand::rng;
use tracing::{debug, info, warn};

use super::{
    MessageSender, MessageSenderError, OutgoingPushMessage,
    OutgoingPushMessages, SendMessageResult,
};
use crate::{
    content::ContentBody,
    proto::{envelope::Type as EnvelopeType, NullMessage},
    push_service::{ServiceError, DEFAULT_DEVICE_ID},
    session_store::SessionStoreExt,
    unidentified_access::UnidentifiedAccess,
    utils::BASE64_RELAXED,
};

fn now_millis() -> u64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .expect("time after the epoch")
        .as_millis() as u64
}

impl<S> MessageSender<S>
where
    S: ProtocolStore + SenderKeyStore + SessionStoreExt + Sync + Clone,
{
    /// Sends a retry request ("retry receipt") to every device of `recipient`.
    ///
    /// As in the official clients, the `DecryptionErrorMessage` goes out as an unencrypted
    /// `PlaintextContent` envelope, so it does not depend on the session that just failed. It
    /// names the device the failed message came from; the recipient's other devices ignore it.
    /// The envelope is identified (not sealed sender).
    ///
    /// Call this *before* archiving the session with the sender: the registration ids of the
    /// recipient's devices are read from the current sessions.
    #[tracing::instrument(skip(self, retry_request), fields(recipient = recipient.service_id_string()))]
    pub async fn send_retry_receipt(
        &mut self,
        recipient: &ServiceId,
        retry_request: &DecryptionErrorMessage,
    ) -> Result<(), MessageSenderError> {
        info!(
            failed_timestamp = retry_request.timestamp().epoch_millis(),
            "sending retry receipt"
        );
        let content = PlaintextContent::from(retry_request.clone());
        let body = BASE64_RELAXED.encode(content.serialized());
        let timestamp = now_millis();

        for _ in 0..4u8 {
            let mut devices: HashSet<DeviceId> = self
                .protocol_store
                .get_sub_device_sessions(recipient)
                .await?
                .into_iter()
                .collect();
            devices.insert(*DEFAULT_DEVICE_ID);
            if *recipient == ServiceId::from(self.local_aci)
                || *recipient == ServiceId::from(self.local_pni)
            {
                devices.remove(&self.device_id);
            }

            let mut messages = Vec::with_capacity(devices.len());
            for device_id in devices {
                match self.remote_registration_id(recipient, device_id).await {
                    Ok(registration_id) => messages.push(OutgoingPushMessage {
                        r#type: EnvelopeType::PlaintextContent as u32,
                        destination_device_id: device_id,
                        destination_registration_id: registration_id,
                        content: body.clone(),
                    }),
                    Err(MessageSenderError::NotFound { .. })
                        if device_id != *DEFAULT_DEVICE_ID =>
                    {
                        debug!(%device_id, "device gone, skipping");
                    },
                    Err(error) => return Err(error),
                }
            }
            if messages.is_empty() {
                return Err(MessageSenderError::NoMessagesToSend);
            }

            let result = self
                .identified_ws
                .send_messages(OutgoingPushMessages {
                    destination: *recipient,
                    timestamp,
                    messages,
                    online: false,
                })
                .await;
            match result {
                Ok(_) => return Ok(()),
                Err(ServiceError::MismatchedDevicesException(ref m)) => {
                    for device_id in &m.extra_devices {
                        self.protocol_store
                            .delete_service_addr_device_session(
                                &ProtocolAddress::new(
                                    recipient.service_id_string(),
                                    *device_id,
                                ),
                            )
                            .await?;
                    }
                    for device_id in &m.missing_devices {
                        self.establish_session(recipient, *device_id).await?;
                    }
                },
                Err(ServiceError::StaleDevices(ref m)) => {
                    for device_id in &m.stale_devices {
                        self.protocol_store
                            .delete_service_addr_device_session(
                                &ProtocolAddress::new(
                                    recipient.service_id_string(),
                                    *device_id,
                                ),
                            )
                            .await?;
                    }
                },
                Err(ServiceError::UnregisteredRecipient) => {
                    return Err(MessageSenderError::NotFound {
                        service_id: *recipient,
                    })
                },
                Err(error) => return Err(error.into()),
            }
        }
        Err(MessageSenderError::MaximumRetriesLimitExceeded)
    }

    /// Sends `content`, originally sent at `timestamp`, again to all devices of `recipient`
    /// (no sync transcript to our own devices: they already have it).
    ///
    /// Used to answer a retry request; the timestamp must be the original one so the
    /// recipient matches it with the message it failed to decrypt.
    pub async fn resend_message(
        &mut self,
        recipient: &ServiceId,
        unidentified_access: Option<&UnidentifiedAccess>,
        content: &ContentBody,
        timestamp: u64,
        include_pni_signature: bool,
    ) -> SendMessageResult {
        self.try_send_message(
            *recipient,
            unidentified_access,
            content,
            timestamp,
            include_pni_signature,
            false,
        )
        .await
    }

    /// Sends a `NullMessage` (invisible to the user) to `recipient`. After the session was
    /// archived, this establishes a new one.
    pub async fn send_null_message(
        &mut self,
        recipient: &ServiceId,
        unidentified_access: Option<&UnidentifiedAccess>,
    ) -> SendMessageResult {
        let content = ContentBody::NullMessage(NullMessage::generate(&mut rng()));
        self.try_send_message(
            *recipient,
            unidentified_access,
            &content,
            now_millis(),
            false,
            false,
        )
        .await
    }

    /// The registration id of `recipient`'s `device_id`, from the session (created from a
    /// fresh pre-key bundle if there is none).
    async fn remote_registration_id(
        &mut self,
        recipient: &ServiceId,
        device_id: DeviceId,
    ) -> Result<u32, MessageSenderError> {
        let address =
            ProtocolAddress::new(recipient.service_id_string(), device_id);
        let current = self
            .protocol_store
            .load_session(&address)
            .await?
            .and_then(|record| record.remote_registration_id().ok());
        if let Some(id) = current {
            return Ok(id);
        }
        self.establish_session(recipient, device_id).await?;
        Ok(self
            .protocol_store
            .load_session(&address)
            .await?
            .ok_or_else(|| MessageSenderError::NotFound {
                service_id: *recipient,
            })?
            .remote_registration_id()?)
    }

    async fn establish_session(
        &mut self,
        recipient: &ServiceId,
        device_id: DeviceId,
    ) -> Result<(), MessageSenderError> {
        let bundles = match self
            .identified_ws
            .get_pre_keys(recipient, device_id)
            .await
        {
            Ok(bundles) => bundles,
            Err(ServiceError::NotFoundError) => {
                return Err(MessageSenderError::NotFound {
                    service_id: *recipient,
                })
            },
            Err(e) => return Err(e.into()),
        };
        let local = ProtocolAddress::new(
            self.local_aci.service_id_string(),
            self.device_id,
        );
        for bundle in bundles {
            let bundle_device = bundle.device_id()?;
            if *recipient == ServiceId::from(self.local_aci)
                && bundle_device == self.device_id
            {
                continue;
            }
            let address = ProtocolAddress::new(
                recipient.service_id_string(),
                bundle_device,
            );
            if let Err(error) = process_prekey_bundle(
                &address,
                &local,
                &mut self.protocol_store.clone(),
                &mut self.protocol_store,
                &bundle,
                SystemTime::now(),
                &mut rng(),
            )
            .await
            {
                warn!(%error, %address, "could not create a session");
                return Err(error.into());
            }
        }
        Ok(())
    }
}
