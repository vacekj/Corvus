//! listIdentities, trust: safety numbers and verification state.

use std::rc::Rc;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as B64;
use presage::libsignal_service::prelude::Uuid;
use presage::libsignal_service::protocol::{
    DeviceId, Fingerprint, IdentityKey, IdentityKeyStore, ProtocolAddress, ServiceId,
};
use presage::store::Store;
use serde_json::{Value, json};

use super::common::*;
use crate::ctx::{Account, Ctx, now_millis};
use crate::method;
use crate::rpc::{Method, RpcError, fail};
use crate::store::IdentityRecord;

pub const METHODS: &[Method] = &[
    method!("listIdentities", list_identities),
    method!("trust", trust),
];

/// Signal's safety number parameters (version 2 = ACI based).
const FINGERPRINT_VERSION: u32 = 2;
const FINGERPRINT_ITERATIONS: u32 = 5200;

async fn their_identity(a: &Account, uuid: &Uuid) -> Result<Option<IdentityKey>, RpcError> {
    let sid: ServiceId = presage::libsignal_service::protocol::Aci::from(*uuid).into();
    let address = ProtocolAddress::new(sid.service_id_string(), DeviceId::new(1).map_err(fail)?);
    a.store.aci_protocol_store().get_identity(&address).await.map_err(fail)
}

pub fn safety_number(own: &Uuid, own_key: &IdentityKey, their: &Uuid, their_key: &IdentityKey) -> Result<(String, Vec<u8>), RpcError> {
    let fp = Fingerprint::new(
        FINGERPRINT_VERSION,
        FINGERPRINT_ITERATIONS,
        own.as_bytes(),
        own_key,
        their.as_bytes(),
        their_key,
    )
    .map_err(fail)?;
    Ok((fp.display_string().map_err(fail)?, fp.scannable.serialize().map_err(fail)?))
}

async fn identity_json(a: &Account, uuid: &Uuid) -> Result<Option<Value>, RpcError> {
    let Some(their_key) = their_identity(a, uuid).await? else { return Ok(None) };
    let own = a.store.aci_protocol_store().get_identity_key_pair().await.map_err(fail)?;
    let (number, scannable) = safety_number(&a.aci, own.identity_key(), uuid, &their_key)?;
    let key_b64 = B64.encode(their_key.serialize());
    let record = match a.local().identity(uuid).await {
        Some(r) if r.key == key_b64 => r,
        // first sight, or the key changed since we recorded it: a change after the user verified
        // the old safety number is untrusted until they look at the new one
        previous => {
            let was_verified = previous.is_some_and(|r| r.level == "TRUSTED_VERIFIED");
            let r = IdentityRecord {
                key: key_b64.clone(),
                added: now_millis(),
                level: if was_verified { "UNTRUSTED" } else { "TRUSTED_UNVERIFIED" }.into(),
            };
            a.local().set_identity(uuid, &r).await.map_err(fail)?;
            r
        }
    };
    Ok(Some(json!({
        "number": a.number_of(uuid).await,
        "uuid": uuid.to_string(),
        "fingerprint": hex::encode(their_key.public_key().serialize()),
        "safetyNumber": number,
        "scannableSafetyNumber": B64.encode(scannable),
        "trustLevel": record.level,
        "addedTimestamp": record.added,
    })))
}

async fn list_identities(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    let a = ctx.account()?;
    let who = str_param(&p, "number").or_else(|| str_param(&p, "recipient"));
    let uuids: Vec<Uuid> = match who {
        Some(w) => vec![a.resolve_aci(&w).await?],
        None => a.contacts().await?.into_iter().map(|c| c.uuid).collect(),
    };
    let mut out = Vec::new();
    for u in uuids {
        if let Some(v) = identity_json(a, &u).await? {
            out.push(v);
        }
    }
    Ok(Value::Array(out))
}

async fn trust(ctx: Rc<Ctx>, p: Value) -> Result<Value, RpcError> {
    let a = ctx.account()?;
    let uuid = a.resolve_aci(&req_str(&p, "recipient")?).await?;
    let Some(v) = identity_json(a, &uuid).await? else {
        return Err(RpcError::failed("No identity key is known for this contact yet"));
    };
    let mut record = a.local().identity(&uuid).await.unwrap_or_default();
    if let Some(given) = str_param(&p, "verifiedSafetyNumber") {
        let digits = |s: &str| s.chars().filter(char::is_ascii_digit).collect::<String>();
        let expected = digits(v["safetyNumber"].as_str().unwrap_or_default());
        if digits(&given) != expected {
            return Err(RpcError::failed("The safety number does not match"));
        }
        record.level = "TRUSTED_VERIFIED".into();
    } else if bool_param(&p, "trustAllKnownKeys") {
        if record.level != "TRUSTED_VERIFIED" {
            record.level = "TRUSTED_UNVERIFIED".into();
        }
    } else {
        return Err(RpcError::invalid_params("verifiedSafetyNumber or trustAllKnownKeys is required"));
    }
    a.local().set_identity(&uuid, &record).await.map_err(fail)?;
    Ok(json!({}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use presage::libsignal_service::protocol::IdentityKeyPair;

    #[test]
    fn safety_number_is_symmetric_and_60_digits() {
        let mut rng = rand::rng();
        let k1 = IdentityKeyPair::generate(&mut rng);
        let k2 = IdentityKeyPair::generate(&mut rng);
        let (u1, u2) = (Uuid::from_u128(1), Uuid::from_u128(2));
        let (n1, _) = safety_number(&u1, k1.identity_key(), &u2, k2.identity_key()).unwrap();
        let (n2, _) = safety_number(&u2, k2.identity_key(), &u1, k1.identity_key()).unwrap();
        assert_eq!(n1.len(), 60);
        assert_eq!(n1, n2);
    }
}
