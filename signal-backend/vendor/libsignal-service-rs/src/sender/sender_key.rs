//! Corvus: group messages with sender keys, as the official clients send them. The message is
//! encrypted once with our sender key for the group and goes to every member device in one
//! sealed-sender multi-recipient request (`PUT /v1/messages/multi_recipient`), instead of one
//! encryption and one request per member. Members get the sender key first, once, in a 1:1
//! message (a sender key distribution message).
//!
//! Anything this path cannot do (a member without an access key, changed devices, a refused
//! request) is left to the per-member send, so nobody misses the message.

use std::collections::HashSet;

use futures::{stream, StreamExt};
use libsignal_protocol::{
    create_sender_key_distribution_message, group_encrypt,
    sealed_sender_multi_recipient_encrypt, CiphertextMessageType, ContentHint,
    DeviceId, ProtocolAddress, ProtocolStore, SenderKeyStore, ServiceId,
    SessionRecord, UnidentifiedSenderMessageContent,
};
use prost::Message as _;
use rand::rng;
use tracing::{info, warn};
use uuid::Uuid;

use super::{
    MessageSender, MessageSenderError, SendMessageResult, SentMessage,
    GROUP_SEND_CONCURRENCY,
};
use crate::{
    content::ContentBody,
    push_service::{ServiceError, DEFAULT_DEVICE_ID},
    session_store::SessionStoreExt,
    unidentified_access::UnidentifiedAccess,
};

/// A group's sender key as far as sending goes; kept by the client between sends.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct SenderKeyState {
    /// Identifies our sender key for the group. A new one (a new key) whenever someone left.
    pub distribution_id: Uuid,
    /// Devices ("<service id>.<device id>") that were sent the key for this distribution id.
    pub shared: HashSet<String>,
}

impl SenderKeyState {
    pub fn device_key(recipient: &ServiceId, device: DeviceId) -> String {
        format!("{}.{}", recipient.service_id_string(), u32::from(device))
    }

    /// The key is sent again to all devices of `recipient` with the next message.
    pub fn forget(&mut self, recipient: &ServiceId) {
        let prefix = format!("{}.", recipient.service_id_string());
        self.shared.retain(|k| !k.starts_with(&prefix));
    }
}

/// What the sender key path did: results for the members it reached (or that are not registered),
/// and the members left for the per-member send.
pub struct SenderKeySend {
    pub results: Vec<SendMessageResult>,
    pub left_over: Vec<ServiceId>,
}

impl<S> MessageSender<S>
where
    S: ProtocolStore + SenderKeyStore + SessionStoreExt + Sync + Clone,
{
    /// Devices of `recipient` we have a session with.
    async fn session_devices(
        &self,
        recipient: &ServiceId,
    ) -> Result<Vec<DeviceId>, MessageSenderError> {
        let mut devices = self
            .protocol_store
            .get_sub_device_sessions(recipient)
            .await?;
        let primary = recipient.to_protocol_address(*DEFAULT_DEVICE_ID);
        if self.protocol_store.load_session(&primary).await?.is_some() {
            devices.push(*DEFAULT_DEVICE_ID);
        }
        Ok(devices)
    }

    /// Sends `content` to `recipients` (members with an unidentified access key) with our sender
    /// key for `distribution_id`. `group_id` is the group identifier (from the master key).
    /// An error means nothing was sent with the sender key: send to everyone per member.
    pub async fn send_sender_key_group_message(
        &mut self,
        recipients: &[(ServiceId, &UnidentifiedAccess)],
        content: &ContentBody,
        timestamp: u64,
        online: bool,
        group_id: Vec<u8>,
        state: &mut SenderKeyState,
    ) -> Result<SenderKeySend, MessageSenderError> {
        let Some((_, first)) = recipients.first() else {
            return Ok(SenderKeySend { results: vec![], left_over: vec![] });
        };
        let certificate = first.certificate.clone();
        let local = ServiceId::from(self.local_aci).to_protocol_address(self.device_id);
        let mut rng = rng();

        // 1. The sender key to whoever does not have it yet.
        let mut left_over = self.distribute_sender_key(recipients, state).await?;
        self.send_with_sender_key(recipients, content, timestamp, online, group_id, state, certificate, local, &mut left_over, &mut rng)
            .await
    }

    /// Sends our sender key for `state.distribution_id` to the members of `recipients` that do not
    /// have it yet (to all their current devices). Returns the members it could not reach. Also used
    /// ahead of a message (the user started typing), so that the message itself goes out at once.
    pub async fn distribute_sender_key(
        &mut self,
        recipients: &[(ServiceId, &UnidentifiedAccess)],
        state: &mut SenderKeyState,
    ) -> Result<Vec<ServiceId>, MessageSenderError> {
        let local = ServiceId::from(self.local_aci).to_protocol_address(self.device_id);
        let mut rng = rng();
        let timestamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or_default();
        let skdm = create_sender_key_distribution_message(
            &local,
            state.distribution_id,
            &mut self.protocol_store,
            &mut rng,
        )
        .await?;
        let skdm_content = crate::proto::Content {
            sender_key_distribution_message: Some(skdm.serialized().to_vec()),
            ..Default::default()
        }
        .encode_to_vec();
        let mut needs_key = Vec::new();
        for (recipient, access) in recipients {
            let devices = self.session_devices(recipient).await?;
            let has_key = !devices.is_empty()
                && devices.iter().all(|d| {
                    state
                        .shared
                        .contains(&SenderKeyState::device_key(recipient, *d))
                });
            if !has_key {
                needs_key.push((*recipient, *access));
            }
        }
        let distributed: Vec<(ServiceId, SendMessageResult)> =
            stream::iter(needs_key.iter())
                .map(|(recipient, access)| {
                    let mut sender = self.clone();
                    let content = &skdm_content;
                    async move {
                        let r = sender
                            .try_send_content(
                                *recipient,
                                Some(*access),
                                content,
                                timestamp,
                                false,
                            )
                            .await;
                        (*recipient, r)
                    }
                })
                .buffered(GROUP_SEND_CONCURRENCY)
                .collect()
                .await;
        let mut left_over = Vec::new();
        for (recipient, result) in distributed {
            match result {
                Ok(_) => {
                    state.forget(&recipient);
                    for d in self.session_devices(&recipient).await? {
                        state.shared.insert(SenderKeyState::device_key(&recipient, d));
                    }
                },
                Err(error) => {
                    info!(%error, "sender key not delivered; that member gets the message on its own");
                    left_over.push(recipient);
                },
            }
        }
        if !needs_key.is_empty() {
            info!(members = needs_key.len(), "sender key distributed");
        }
        Ok(left_over)
    }

    #[allow(clippy::too_many_arguments)]
    async fn send_with_sender_key<R: rand::Rng + rand::CryptoRng>(
        &mut self,
        recipients: &[(ServiceId, &UnidentifiedAccess)],
        content: &ContentBody,
        timestamp: u64,
        online: bool,
        group_id: Vec<u8>,
        state: &mut SenderKeyState,
        certificate: libsignal_protocol::SenderCertificate,
        local: ProtocolAddress,
        left_over: &mut Vec<ServiceId>,
        rng: &mut R,
    ) -> Result<SenderKeySend, MessageSenderError> {
        let mut rng = rng;
        // 2. One encryption for every device of the members that have the key.
        let mut members: Vec<(ServiceId, &UnidentifiedAccess)> = Vec::new();
        let mut addresses: Vec<ProtocolAddress> = Vec::new();
        let mut sessions: Vec<SessionRecord> = Vec::new();
        for (recipient, access) in recipients {
            if left_over.contains(recipient) {
                continue;
            }
            let devices = self.session_devices(recipient).await?;
            let mut any = false;
            for d in devices {
                let address = recipient.to_protocol_address(d);
                if let Some(session) = self.protocol_store.load_session(&address).await? {
                    addresses.push(address);
                    sessions.push(session);
                    any = true;
                }
            }
            if any {
                members.push((*recipient, *access));
            } else {
                left_over.push(*recipient);
            }
        }
        if members.is_empty() {
            return Ok(SenderKeySend { results: vec![], left_over: std::mem::take(left_over) });
        }

        let padded = crate::cipher::add_padding(3, &content.clone().into_proto().encode_to_vec())?;
        let message = group_encrypt(
            &mut self.protocol_store,
            &local,
            state.distribution_id,
            &padded,
            &mut rng,
        )
        .await?;
        let usmc = UnidentifiedSenderMessageContent::new(
            CiphertextMessageType::SenderKey,
            certificate,
            message.serialized().to_vec(),
            ContentHint::Resendable,
            Some(group_id),
        )?;
        let address_refs: Vec<&ProtocolAddress> = addresses.iter().collect();
        let session_refs: Vec<&SessionRecord> = sessions.iter().collect();
        let payload = sealed_sender_multi_recipient_encrypt(
            &address_refs,
            &session_refs,
            Vec::<ServiceId>::new(),
            &usmc,
            &self.protocol_store,
            &mut rng,
        )
        .await?;

        // 3. One request, authorized with the XOR of the members' access keys.
        let mut combined = vec![0u8; 16];
        for (_, access) in &members {
            for (c, k) in combined.iter_mut().zip(access.key.iter()) {
                *c ^= k;
            }
        }
        let sent = self
            .unidentified_ws
            .send_multi_recipient_message(payload, &combined, timestamp, online)
            .await;
        let response = match sent {
            Ok(response) => response,
            Err(ServiceError::MultiRecipientMismatchedDevices(accounts)) => {
                for account in accounts {
                    state.forget(&account.uuid);
                    for d in &account.devices.extra_devices {
                        let _ = self
                            .protocol_store
                            .delete_service_addr_device_session(
                                &account.uuid.to_protocol_address(*d),
                            )
                            .await;
                    }
                }
                return Err(MessageSenderError::ServiceError(
                    ServiceError::InvalidFrame { reason: "mismatched devices in a multi-recipient send" },
                ));
            },
            Err(ServiceError::MultiRecipientStaleDevices(accounts)) => {
                for account in accounts {
                    state.forget(&account.uuid);
                    for d in &account.devices.stale_devices {
                        let _ = self
                            .protocol_store
                            .delete_service_addr_device_session(
                                &account.uuid.to_protocol_address(*d),
                            )
                            .await;
                    }
                }
                return Err(MessageSenderError::ServiceError(
                    ServiceError::InvalidFrame { reason: "stale devices in a multi-recipient send" },
                ));
            },
            Err(error) => {
                warn!(%error, "multi-recipient send refused");
                return Err(error.into());
            },
        };

        let unregistered: HashSet<&str> =
            response.uuids404.iter().map(String::as_str).collect();
        let mut results = Vec::with_capacity(members.len());
        for (recipient, _) in members {
            let id = recipient.service_id_string();
            if unregistered.contains(id.as_str()) {
                results.push(Err(MessageSenderError::NotFound { service_id: recipient }));
                continue;
            }
            let address = recipient.to_protocol_address(*DEFAULT_DEVICE_ID);
            match self.protocol_store.get_identity(&address).await? {
                Some(used_identity_key) => results.push(Ok(SentMessage {
                    recipient,
                    used_identity_key,
                    unidentified: true,
                    needs_sync: false,
                })),
                None => left_over.push(recipient), // no identity to report: sent again on its own
            }
        }
        info!(
            members = results.len(),
            devices = addresses.len(),
            left_over = left_over.len(),
            "group message sent with the sender key"
        );
        Ok(SenderKeySend { results, left_over: std::mem::take(left_over) })
    }
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, SystemTime};

    use aes::cipher::block_padding::{Iso7816, Padding};
    use libsignal_protocol::*;
    use prost::Message;
    use rand::rng;

    use crate::content::ContentBody;
    use crate::proto::DataMessage;

    struct Party {
        store: InMemSignalProtocolStore,
        address: ProtocolAddress,
        id: ServiceId,
    }

    fn party(n: u128) -> Party {
        let identity = IdentityKeyPair::generate(&mut rng());
        let aci = Aci::from(uuid::Uuid::from_u128(n));
        Party {
            store: InMemSignalProtocolStore::new(identity, n as u32).unwrap(),
            address: ProtocolAddress::new(aci.service_id_string(), DeviceId::try_from(1u32).unwrap()),
            id: aci.into(),
        }
    }

    async fn bundle(p: &mut Party) -> PreKeyBundle {
        let mut csprng = rng();
        let identity = p.store.get_identity_key_pair().await.unwrap();
        let pre_key = KeyPair::generate(&mut csprng);
        let signed = KeyPair::generate(&mut csprng);
        let kyber = kem::KeyPair::generate(kem::KeyType::Kyber1024, &mut csprng);
        let signed_sig = identity.private_key().calculate_signature(&signed.public_key.serialize(), &mut csprng).unwrap();
        let kyber_sig = identity.private_key().calculate_signature(&kyber.public_key.serialize(), &mut csprng).unwrap();
        p.store.save_pre_key(1.into(), &PreKeyRecord::new(1.into(), &pre_key)).await.unwrap();
        p.store
            .save_signed_pre_key(2.into(), &SignedPreKeyRecord::new(2.into(), Timestamp::from_epoch_millis(1), &signed, &signed_sig))
            .await
            .unwrap();
        p.store
            .save_kyber_pre_key(3.into(), &KyberPreKeyRecord::new(3.into(), Timestamp::from_epoch_millis(1), &kyber, &kyber_sig))
            .await
            .unwrap();
        let registration_id = p.store.get_local_registration_id().await.unwrap();
        PreKeyBundle::new(
            registration_id,
            p.address.device_id(),
            Some((1.into(), pre_key.public_key)),
            2.into(),
            signed.public_key,
            signed_sig.to_vec(),
            3.into(),
            kyber.public_key.clone(),
            kyber_sig.to_vec(),
            *identity.identity_key(),
        )
        .unwrap()
    }

    /// The steps of `send_sender_key_group_message` (key distribution, padding, group encryption,
    /// sealed sender v2) end to end: each member reads the message from its part of the
    /// multi-recipient payload as the server hands it out.
    #[tokio::test]
    async fn group_message_with_sender_key_decrypts_for_each_member() {
        let mut csprng = rng();
        let mut alice = party(1);
        let mut members = vec![party(2), party(3), party(4)];
        for m in members.iter_mut() {
            let b = bundle(m).await;
            process_prekey_bundle(
                &m.address,
                &alice.address,
                &mut alice.store.session_store,
                &mut alice.store.identity_store,
                &b,
                SystemTime::now(),
                &mut csprng,
            )
            .await
            .unwrap();
        }

        // the key, in the 1:1 content the members are sent first
        let distribution_id = uuid::Uuid::from_u128(99);
        let skdm = create_sender_key_distribution_message(&alice.address, distribution_id, &mut alice.store, &mut csprng)
            .await
            .unwrap();
        let skdm_content = crate::proto::Content {
            sender_key_distribution_message: Some(skdm.serialized().to_vec()),
            ..Default::default()
        }
        .encode_to_vec();
        for m in members.iter_mut() {
            let content = crate::proto::Content::decode(skdm_content.as_slice()).unwrap();
            let received = SenderKeyDistributionMessage::try_from(&content.sender_key_distribution_message.unwrap()[..]).unwrap();
            process_sender_key_distribution_message(&alice.address, &received, &mut m.store).await.unwrap();
        }

        // the message
        let body = ContentBody::DataMessage(DataMessage { body: Some("hello group".into()), timestamp: Some(5), ..Default::default() });
        let padded = crate::cipher::add_padding(3, &body.clone().into_proto().encode_to_vec()).unwrap();
        assert_eq!(padded.len() % 160, 0);
        let message = group_encrypt(&mut alice.store, &alice.address, distribution_id, &padded, &mut csprng).await.unwrap();

        let trust_root = KeyPair::generate(&mut csprng);
        let server_key = KeyPair::generate(&mut csprng);
        let server_certificate = ServerCertificate::new(1, server_key.public_key, &trust_root.private_key, &mut csprng).unwrap();
        let alice_identity = alice.store.get_identity_key_pair().await.unwrap();
        let expires = SystemTime::now() + Duration::from_secs(3600);
        let certificate = SenderCertificate::new(
            alice.id.service_id_string(),
            None,
            *alice_identity.public_key(),
            alice.address.device_id(),
            Timestamp::from_epoch_millis(expires.duration_since(SystemTime::UNIX_EPOCH).unwrap().as_millis() as u64),
            server_certificate,
            &server_key.private_key,
            &mut csprng,
        )
        .unwrap();
        let group_id = vec![7u8; 32];
        let usmc = UnidentifiedSenderMessageContent::new(
            CiphertextMessageType::SenderKey,
            certificate,
            message.serialized().to_vec(),
            ContentHint::Resendable,
            Some(group_id.clone()),
        )
        .unwrap();
        let mut sessions = Vec::new();
        for m in &members {
            sessions.push(alice.store.load_session(&m.address).await.unwrap().unwrap());
        }
        let addresses: Vec<&ProtocolAddress> = members.iter().map(|m| &m.address).collect();
        let session_refs: Vec<&SessionRecord> = sessions.iter().collect();
        let payload = sealed_sender_multi_recipient_encrypt(
            &addresses,
            &session_refs,
            Vec::<ServiceId>::new(),
            &usmc,
            &alice.store,
            &mut csprng,
        )
        .await
        .unwrap();

        // what the server does with it, then each member
        let sent = SealedSenderV2SentMessage::parse(&payload).unwrap();
        assert_eq!(sent.recipients.len(), members.len());
        for m in members.iter_mut() {
            let part = &sent.recipients[&m.id];
            let bytes = sent.received_message_parts_for_recipient(part).as_ref().concat();
            let received = sealed_sender_decrypt_to_usmc(&bytes, &m.store.identity_store).await.unwrap();
            assert_eq!(received.msg_type().unwrap(), CiphertextMessageType::SenderKey);
            assert_eq!(received.group_id().unwrap(), Some(&group_id[..]));
            assert_eq!(received.sender().unwrap().sender_uuid().unwrap(), alice.id.service_id_string());
            let mut plain = group_decrypt(received.contents().unwrap(), &mut m.store, &alice.address).await.unwrap();
            let len = Iso7816::raw_unpad(&plain).unwrap().len();
            plain.truncate(len);
            let content = crate::proto::Content::decode(plain.as_slice()).unwrap();
            match content.content {
                Some(crate::proto::content::Content::DataMessage(dm)) => {
                    assert_eq!(dm.body.as_deref(), Some("hello group"))
                },
                other => panic!("not a data message: {other:?}"),
            }
        }
    }

    #[test]
    fn forget_drops_every_device_of_a_member() {
        let a: ServiceId = Aci::from(uuid::Uuid::from_u128(5)).into();
        let b: ServiceId = Aci::from(uuid::Uuid::from_u128(6)).into();
        let mut state = super::SenderKeyState::default();
        for (who, d) in [(a, 1u32), (a, 2), (b, 1)] {
            state.shared.insert(super::SenderKeyState::device_key(&who, DeviceId::try_from(d).unwrap()));
        }
        state.forget(&a);
        assert_eq!(state.shared.len(), 1);
        assert!(state.shared.iter().all(|k| k.starts_with(&b.service_id_string())));
    }
}
