//! [`CallBackend`] on a registered presage [`Manager`]. The backend can use it as is or copy
//! the pieces it needs (e.g. when it resolves recipients through its own contact table).

use std::time::{SystemTime, UNIX_EPOCH};

use presage::Manager;
use presage::libsignal_service::prelude::{Uuid, phonenumber};
use presage::libsignal_service::protocol::{
    DeviceId, IdentityKeyStore, ProtocolAddress, ServiceId,
};
use presage::manager::Registered;
use presage::proto::CallMessage;
use presage::store::Store;

use crate::backend::{CallBackend, CallError, IceServer, Peer};

pub struct PresageCallBackend<S: Store> {
    manager: Manager<S, Registered>,
}

impl<S: Store> PresageCallBackend<S> {
    /// `manager` is a clone of the backend's registered manager.
    pub fn new(manager: Manager<S, Registered>) -> Self {
        Self { manager }
    }
}

fn fail(context: &str, e: impl std::fmt::Display) -> CallError {
    CallError::new(format!("{context}: {e}"))
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or_default()
}

impl<S: Store> CallBackend for PresageCallBackend<S> {
    fn local_device_id(&self) -> u32 {
        u32::from(self.manager.device_id())
    }

    async fn resolve_recipient(&self, recipient: &str) -> Result<Peer, CallError> {
        let store = self.manager.store();
        if let Ok(aci) = Uuid::parse_str(recipient) {
            let number = store
                .contact_by_id(&ServiceId::Aci(aci.into()))
                .await
                .ok()
                .flatten()
                .and_then(|c| c.phone_number)
                .map(|n| n.format().mode(phonenumber::Mode::E164).to_string());
            return Ok(Peer::new(aci, number));
        }
        let contacts = store
            .contacts()
            .await
            .map_err(|e| fail("Failed to read contacts", e))?;
        for contact in contacts.flatten() {
            if let Some(n) = &contact.phone_number {
                let e164 = n.format().mode(phonenumber::Mode::E164).to_string();
                if e164 == recipient {
                    return Ok(Peer::new(contact.uuid, Some(e164)));
                }
            }
        }
        Err(CallError::new(format!(
            "Recipient not registered: {recipient}"
        )))
    }

    async fn send_call_message(&self, peer: &Peer, message: CallMessage) -> Result<(), CallError> {
        // CallMessages are not saved to a thread by presage, and lss sends no sync transcript
        // for them.
        let mut manager = self.manager.clone();
        manager
            .send_message(ServiceId::Aci(peer.aci.into()), message, now_ms())
            .await
            .map_err(|e| fail("Failed to send call message", e))
    }

    async fn turn_servers(&self) -> Result<Vec<IceServer>, CallError> {
        let relays = self
            .manager
            .calling_relays()
            .await
            .map_err(|e| fail("Failed to get TURN servers", e))?;
        // Like signal-cli: username, password and the plain `urls`.
        Ok(relays
            .into_iter()
            .map(|t| IceServer {
                username: t.username,
                password: t.password,
                urls: t.urls,
            })
            .collect())
    }

    async fn local_identity_key(&self) -> Result<Vec<u8>, CallError> {
        let pair = self
            .manager
            .store()
            .aci_protocol_store()
            .get_identity_key_pair()
            .await
            .map_err(|e| fail("Failed to read our identity key", e))?;
        Ok(pair.identity_key().serialize().to_vec())
    }

    async fn remote_identity_key(&self, peer: &Peer) -> Result<Vec<u8>, CallError> {
        let device = DeviceId::new(1).expect("1 is a valid device id");
        let address = ProtocolAddress::new(peer.aci.to_string(), device);
        self.manager
            .store()
            .aci_protocol_store()
            .get_identity(&address)
            .await
            .map_err(|e| fail("Failed to read the peer's identity key", e))?
            .map(|k| k.serialize().to_vec())
            .ok_or_else(|| CallError::new("The peer's identity key is unknown"))
    }
}
