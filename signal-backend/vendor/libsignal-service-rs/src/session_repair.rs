//! Corvus: decryption-error recovery ("retry receipts"), as in Signal-Android/Desktop.
//!
//! When we cannot decrypt an envelope, we send the sender a `DecryptionErrorMessage` (wrapped in
//! a `PlaintextContent`, so it does not depend on the broken session) naming the message's
//! timestamp, the device that sent it and, for 1:1 messages, the ratchet key it was encrypted
//! with. See [`analyze_decryption_failure`] and
//! [`MessageSender::send_retry_receipt`](crate::sender::MessageSender::send_retry_receipt).
//!
//! When we receive such a request, we archive our session with the requesting device if the
//! ratchet key matches our current sending chain ([`archive_session_for_retry_request`]), then
//! resend the message if we still have it, or else send a null message so the next message
//! starts a fresh session.

use libsignal_protocol::{
    sealed_sender_decrypt_to_usmc, Aci, CiphertextMessageType,
    DecryptionErrorMessage, DeviceId, IdentityKeyStore, ProtocolAddress,
    PublicKey, ServiceId, SessionStore, SignalProtocolError, Timestamp,
};

use crate::{
    cipher::SealedSenderDecryptionError,
    envelope::Envelope,
    proto::envelope::Type as EnvelopeType,
    push_service::ServiceError,
};

/// Why decrypting an envelope failed, as far as recovery is concerned.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DecryptionFailureKind {
    /// The session or pre-key state does not match the sender's: ask for a resend.
    Retryable,
    /// We already decrypted this message (e.g. redelivered after a crash before the ack).
    Duplicate,
    /// The sender's identity key is not trusted; a resend would fail the same way.
    UntrustedIdentity,
    /// Anything else (malformed envelope, unverifiable sealed sender, ...): nothing to do.
    Other,
}

impl DecryptionFailureKind {
    pub fn of(error: &ServiceError) -> Self {
        match error {
            ServiceError::SignalProtocolError(e) => Self::of_protocol(e),
            ServiceError::SealedSenderDecryptionError(
                SealedSenderDecryptionError { inner, .. },
            ) => Self::of_protocol(inner),
            _ => Self::Other,
        }
    }

    fn of_protocol(error: &SignalProtocolError) -> Self {
        use SignalProtocolError as E;
        match error {
            E::DuplicatedMessage(..) => Self::Duplicate,
            E::UntrustedIdentity(_) => Self::UntrustedIdentity,
            E::SealedSenderSelfSend
            | E::InvalidSealedSenderMessage(_)
            | E::UnknownSealedSenderVersion(_)
            | E::UnknownSealedSenderServerCertificateId(_)
            | E::InvalidArgument(_)
            | E::FfiBindingError(_)
            | E::ApplicationCallbackError(..) => Self::Other,
            _ => Self::Retryable,
        }
    }
}

/// What we know about an envelope we could not decrypt.
#[derive(Debug, Clone)]
pub struct FailedDecryption {
    pub sender: ServiceId,
    pub sender_device: DeviceId,
    /// The envelope's (sender-side) timestamp.
    pub timestamp: u64,
    pub message_type: CiphertextMessageType,
    /// Group id of a sealed-sender group message, if the sender put one in.
    pub group_id: Option<Vec<u8>>,
    pub kind: DecryptionFailureKind,
    /// The retry request to send to `sender`, when `kind` is `Retryable`.
    pub retry_request: Option<DecryptionErrorMessage>,
}

impl FailedDecryption {
    /// The protocol address of the device that sent the message.
    pub fn sender_address(&self) -> ProtocolAddress {
        ProtocolAddress::new(
            self.sender.service_id_string(),
            self.sender_device,
        )
    }
}

/// Works out who sent an envelope that failed to decrypt with `error`, and builds the retry
/// request for it.
///
/// Returns `None` when the sender cannot be identified (an unsealed envelope without source, or a
/// sealed-sender envelope whose sender certificate does not validate against `trust_roots`).
pub async fn analyze_decryption_failure<S: IdentityKeyStore>(
    envelope: &Envelope,
    error: &ServiceError,
    identity_store: &S,
    trust_roots: &[PublicKey],
) -> Option<FailedDecryption> {
    let kind = DecryptionFailureKind::of(error);
    let timestamp = envelope.client_timestamp();
    let ciphertext = envelope.content.as_deref()?;

    let (sender, sender_device, message_type, bytes, group_id) =
        match envelope.r#type() {
            EnvelopeType::PrekeyMessage | EnvelopeType::DoubleRatchet => {
                let sender = envelope.parse_source_service_id()?;
                let device = DeviceId::try_from(envelope.source_device_id())
                    .ok()?;
                let message_type =
                    if envelope.r#type() == EnvelopeType::PrekeyMessage {
                        CiphertextMessageType::PreKey
                    } else {
                        CiphertextMessageType::Whisper
                    };
                (sender, device, message_type, ciphertext.to_vec(), None)
            },
            EnvelopeType::UnidentifiedSender => {
                let usmc =
                    sealed_sender_decrypt_to_usmc(ciphertext, identity_store)
                        .await
                        .ok()?;
                let certificate = usmc.sender().ok()?;
                if !certificate
                    .validate_with_trust_roots(
                        trust_roots,
                        Timestamp::from_epoch_millis(timestamp),
                    )
                    .ok()?
                {
                    tracing::warn!(
                        "sealed sender certificate of an undecryptable message does not validate"
                    );
                    return None;
                }
                let sender: ServiceId = certificate
                    .sender_uuid()
                    .ok()?
                    .parse::<uuid::Uuid>()
                    .ok()
                    .map(|uuid| Aci::from(uuid).into())?;
                (
                    sender,
                    certificate.sender_device_id().ok()?,
                    usmc.msg_type().ok()?,
                    usmc.contents().ok()?.to_vec(),
                    usmc.group_id().ok()?.map(<[u8]>::to_vec),
                )
            },
            _ => return None,
        };

    let retry_request = match (kind, message_type) {
        (_, CiphertextMessageType::Plaintext) => None,
        (DecryptionFailureKind::Retryable, _) => {
            DecryptionErrorMessage::for_original(
                &bytes,
                message_type,
                Timestamp::from_epoch_millis(timestamp),
                sender_device.into(),
            )
            .inspect_err(|error| {
                tracing::warn!(%error, "cannot build a retry request");
            })
            .ok()
        },
        _ => None,
    };

    Some(FailedDecryption {
        sender,
        sender_device,
        timestamp,
        message_type,
        group_id,
        kind,
        retry_request,
    })
}

/// A retry request we received, parsed.
#[derive(Debug, Clone)]
pub struct RetryRequest {
    /// The timestamp of the message the requester could not decrypt.
    pub timestamp: u64,
    /// Our device the failed message came from; requests for other devices are not ours.
    pub device_id: u32,
    /// Ratchet key of the failed 1:1 message; `None` for sender-key (group) messages.
    pub ratchet_key: Option<PublicKey>,
}

impl RetryRequest {
    pub fn from_proto(
        message: &crate::proto::DecryptionErrorMessage,
    ) -> Option<Self> {
        Some(Self {
            timestamp: message.timestamp?,
            device_id: message.device_id?,
            ratchet_key: match message.ratchet_key.as_deref() {
                Some(bytes) => Some(PublicKey::deserialize(bytes).ok()?),
                None => None,
            },
        })
    }
}

/// Archives our session with `address` when the retry request's ratchet key is the one our
/// current session sends with (the requester really is out of sync with that session).
///
/// Returns whether a session was archived. The next message to `address` then starts a new
/// session from a fresh pre-key bundle.
pub async fn archive_session_for_retry_request<S: SessionStore>(
    store: &mut S,
    address: &ProtocolAddress,
    ratchet_key: Option<&PublicKey>,
) -> Result<bool, SignalProtocolError> {
    let Some(ratchet_key) = ratchet_key else {
        return Ok(false);
    };
    let Some(mut record) = store.load_session(address).await? else {
        return Ok(false);
    };
    if !record.current_ratchet_key_matches(ratchet_key)? {
        return Ok(false);
    }
    record.archive_current_state()?;
    store.store_session(address, &record).await?;
    Ok(true)
}

/// Archives our current session with `address`, if any (a "session reset" from our side).
///
/// Archived states are still tried when decrypting, so in-flight messages keep working; new
/// messages to `address` start a fresh session.
pub async fn archive_session<S: SessionStore>(
    store: &mut S,
    address: &ProtocolAddress,
) -> Result<bool, SignalProtocolError> {
    let Some(mut record) = store.load_session(address).await? else {
        return Ok(false);
    };
    if record.session_version().is_err() {
        // no current state
        return Ok(false);
    }
    record.archive_current_state()?;
    store.store_session(address, &record).await?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, SystemTime};

    use libsignal_protocol::*;
    use prost::Message;
    use rand::{rng, Rng};

    use super::*;
    use crate::proto::Envelope;

    struct Party {
        store: InMemSignalProtocolStore,
        address: ProtocolAddress,
        aci: Aci,
    }

    fn party(device: u8) -> Party {
        let identity = IdentityKeyPair::generate(&mut rng());
        let aci = Aci::from(uuid::Uuid::from_u128(rand::random()));
        Party {
            store: InMemSignalProtocolStore::new(identity, 42).unwrap(),
            address: ProtocolAddress::new(
                aci.service_id_string(),
                DeviceId::try_from(u32::from(device)).unwrap(),
            ),
            aci,
        }
    }

    async fn bundle(party: &mut Party) -> PreKeyBundle {
        let mut csprng = rng();
        let store = &mut party.store;
        let identity = store.get_identity_key_pair().await.unwrap();
        let pre_key = KeyPair::generate(&mut csprng);
        let signed = KeyPair::generate(&mut csprng);
        let kyber = kem::KeyPair::generate(kem::KeyType::Kyber1024, &mut csprng);
        let signed_sig = identity
            .private_key()
            .calculate_signature(&signed.public_key.serialize(), &mut csprng)
            .unwrap();
        let kyber_sig = identity
            .private_key()
            .calculate_signature(&kyber.public_key.serialize(), &mut csprng)
            .unwrap();
        store
            .save_pre_key(1.into(), &PreKeyRecord::new(1.into(), &pre_key))
            .await
            .unwrap();
        store
            .save_signed_pre_key(
                2.into(),
                &SignedPreKeyRecord::new(
                    2.into(),
                    Timestamp::from_epoch_millis(1),
                    &signed,
                    &signed_sig,
                ),
            )
            .await
            .unwrap();
        store
            .save_kyber_pre_key(
                3.into(),
                &KyberPreKeyRecord::new(
                    3.into(),
                    Timestamp::from_epoch_millis(1),
                    &kyber,
                    &kyber_sig,
                ),
            )
            .await
            .unwrap();
        PreKeyBundle::new(
            42,
            party.address.device_id(),
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

    /// Alice starts a session with Bob and encrypts one message.
    async fn alice_to_bob() -> (Party, Party, CiphertextMessage) {
        let mut alice = party(1);
        let mut bob = party(3);
        let bob_bundle = bundle(&mut bob).await;
        process_prekey_bundle(
            &bob.address,
            &alice.address,
            &mut alice.store.session_store,
            &mut alice.store.identity_store,
            &bob_bundle,
            SystemTime::now(),
            &mut rng(),
        )
        .await
        .unwrap();
        let message = message_encrypt(
            b"hello",
            &bob.address,
            &alice.address,
            &mut alice.store.session_store,
            &mut alice.store.identity_store,
            SystemTime::now(),
            &mut rng(),
        )
        .await
        .unwrap();
        (alice, bob, message)
    }

    #[tokio::test]
    async fn retry_request_for_unsealed_prekey_message() {
        let (mut alice, bob, message) = alice_to_bob().await;
        assert_eq!(message.message_type(), CiphertextMessageType::PreKey);

        let envelope = Envelope {
            r#type: Some(EnvelopeType::PrekeyMessage.into()),
            source_service_id: Some(alice.aci.service_id_string()),
            source_device_id: Some(1),
            destination_service_id: Some(bob.aci.service_id_string()),
            client_timestamp: Some(1_700_000_000_123),
            content: Some(message.serialize().to_vec()),
            ..Default::default()
        };
        let error = ServiceError::SignalProtocolError(
            SignalProtocolError::InvalidPreKeyId,
        );
        let failed = analyze_decryption_failure(
            &envelope,
            &error,
            &bob.store.identity_store,
            &[],
        )
        .await
        .unwrap();

        assert_eq!(failed.sender, ServiceId::from(alice.aci));
        assert_eq!(failed.sender_device, DeviceId::try_from(1u32).unwrap());
        assert_eq!(failed.timestamp, 1_700_000_000_123);
        assert_eq!(failed.kind, DecryptionFailureKind::Retryable);
        let request = failed.retry_request.unwrap();
        assert_eq!(request.timestamp().epoch_millis(), 1_700_000_000_123);
        assert_eq!(request.device_id(), 1);

        // Alice receives the request (as the proto inside the Content) and archives her session.
        let proto = crate::proto::DecryptionErrorMessage::decode(
            request.serialized(),
        )
        .unwrap();
        let parsed = RetryRequest::from_proto(&proto).unwrap();
        assert_eq!(parsed.timestamp, 1_700_000_000_123);
        assert!(parsed.ratchet_key.is_some());

        let other_key = KeyPair::generate(&mut rng()).public_key;
        assert!(!archive_session_for_retry_request(
            &mut alice.store.session_store,
            &bob.address,
            Some(&other_key),
        )
        .await
        .unwrap());
        assert!(archive_session_for_retry_request(
            &mut alice.store.session_store,
            &bob.address,
            parsed.ratchet_key.as_ref(),
        )
        .await
        .unwrap());
        let record = alice
            .store
            .session_store
            .load_session(&bob.address)
            .await
            .unwrap()
            .unwrap();
        assert!(record.session_version().is_err());
        // nothing left to archive
        assert!(!archive_session(&mut alice.store.session_store, &bob.address)
            .await
            .unwrap());
    }

    #[tokio::test]
    async fn retry_request_for_sealed_sender_message() {
        let (alice, mut bob, message) = alice_to_bob().await;
        let mut csprng = rng();
        let trust_root = KeyPair::generate(&mut csprng);
        let server_key = KeyPair::generate(&mut csprng);
        let server_certificate = ServerCertificate::new(
            1,
            server_key.public_key,
            &trust_root.private_key,
            &mut csprng,
        )
        .unwrap();
        let alice_identity =
            alice.store.get_identity_key_pair().await.unwrap();
        let expires = SystemTime::now() + Duration::from_secs(3600);
        let sender_certificate = SenderCertificate::new(
            alice.aci.service_id_string(),
            None,
            *alice_identity.public_key(),
            alice.address.device_id(),
            Timestamp::from_epoch_millis(
                expires
                    .duration_since(SystemTime::UNIX_EPOCH)
                    .unwrap()
                    .as_millis() as u64,
            ),
            server_certificate,
            &server_key.private_key,
            &mut csprng,
        )
        .unwrap();
        let group_id = vec![7u8; 32];
        let usmc = UnidentifiedSenderMessageContent::new(
            message.message_type(),
            sender_certificate,
            message.serialize().to_vec(),
            ContentHint::Resendable,
            Some(group_id.clone()),
        )
        .unwrap();
        // Bob needs Alice's identity for the sealed sender layer
        bob.store
            .identity_store
            .save_identity(&alice.address, alice_identity.identity_key())
            .await
            .unwrap();
        let sealed = sealed_sender_encrypt_from_usmc(
            &bob.address,
            &usmc,
            &alice.store.identity_store,
            &mut csprng,
        )
        .await
        .unwrap();

        let now = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64;
        let envelope = Envelope {
            r#type: Some(EnvelopeType::UnidentifiedSender.into()),
            destination_service_id: Some(bob.aci.service_id_string()),
            client_timestamp: Some(now),
            content: Some(sealed),
            ..Default::default()
        };
        let error = ServiceError::SealedSenderDecryptionError(
            SealedSenderDecryptionError {
                inner: SignalProtocolError::InvalidMessage(
                    CiphertextMessageType::PreKey,
                    "test".into(),
                ),
                sender: Some(alice.address.clone()),
            },
        );

        // without the right trust root, the sender cannot be trusted
        assert!(analyze_decryption_failure(
            &envelope,
            &error,
            &bob.store.identity_store,
            &[KeyPair::generate(&mut csprng).public_key],
        )
        .await
        .is_none());

        let failed = analyze_decryption_failure(
            &envelope,
            &error,
            &bob.store.identity_store,
            &[trust_root.public_key],
        )
        .await
        .unwrap();
        assert_eq!(failed.sender, ServiceId::from(alice.aci));
        assert_eq!(failed.group_id, Some(group_id));
        assert_eq!(failed.message_type, CiphertextMessageType::PreKey);
        let request = failed.retry_request.unwrap();
        assert_eq!(request.timestamp().epoch_millis(), now);
        assert!(request.ratchet_key().is_some());
    }

    #[tokio::test]
    async fn duplicates_and_untrusted_identities_get_no_retry_request() {
        let (alice, bob, message) = alice_to_bob().await;
        let envelope = Envelope {
            r#type: Some(EnvelopeType::PrekeyMessage.into()),
            source_service_id: Some(alice.aci.service_id_string()),
            source_device_id: Some(1),
            client_timestamp: Some(rng().random_range(1..1_000_000)),
            content: Some(message.serialize().to_vec()),
            ..Default::default()
        };
        for (error, kind) in [
            (
                SignalProtocolError::DuplicatedMessage(1, 2),
                DecryptionFailureKind::Duplicate,
            ),
            (
                SignalProtocolError::UntrustedIdentity(alice.address.clone()),
                DecryptionFailureKind::UntrustedIdentity,
            ),
        ] {
            let failed = analyze_decryption_failure(
                &envelope,
                &ServiceError::SignalProtocolError(error),
                &bob.store.identity_store,
                &[],
            )
            .await
            .unwrap();
            assert_eq!(failed.kind, kind);
            assert!(failed.retry_request.is_none());
        }
        assert_eq!(
            DecryptionFailureKind::of(&ServiceError::InvalidFrame {
                reason: "x"
            }),
            DecryptionFailureKind::Other
        );
    }
}
