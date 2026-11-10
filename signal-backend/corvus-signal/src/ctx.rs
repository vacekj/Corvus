//! Shared state of the `jsonRpc` process: the data dir, the stdout writer and (when linked) the
//! presage manager with helpers to resolve recipients and groups.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use std::time::{Duration, Instant};

use presage::Manager;
use presage::libsignal_service::prelude::{ProfileKey, Uuid};
use presage::libsignal_service::protocol::{Aci, ServiceId};
use presage::manager::Registered;
use presage::model::contacts::Contact;
use presage::model::groups::Group;
use presage::store::ContentsStore;
use presage_store_sqlite::SqliteStore;

use crate::envelope::{Lookup, group_id_from_master_key};
use crate::files::DataDir;
use crate::rpc::{Output, RpcError, fail};
use crate::store::Local;

pub type Mgr = Manager<SqliteStore, Registered>;

pub struct Ctx {
    pub dir: DataDir,
    pub out: Output,
    account: Option<Account>,
    unavailable: String,
}

impl Ctx {
    pub fn linked(dir: DataDir, out: Output, account: Account) -> Self {
        Self {
            dir,
            out,
            account: Some(account),
            unavailable: String::new(),
        }
    }

    /// A process that answers every account method with `reason`.
    pub fn unlinked(dir: DataDir, out: Output, reason: impl Into<String>) -> Self {
        Self {
            dir,
            out,
            account: None,
            unavailable: reason.into(),
        }
    }

    pub fn account(&self) -> Result<&Account, RpcError> {
        self.account
            .as_ref()
            .ok_or_else(|| RpcError::new(crate::rpc::NOT_LINKED, self.unavailable.clone()))
    }

    pub fn has_account(&self) -> bool {
        self.account.is_some()
    }
}

pub struct Account {
    pub store: SqliteStore,
    manager: Mgr,
    pub aci: Uuid,
    pub pni: Uuid,
    pub number: String,
    pub device_id: u32,
    directory: RefCell<Option<(Instant, Rc<Directory>)>>,
}

/// Number and group-name lookups for the envelope mapping, cached briefly.
#[derive(Default)]
pub struct Directory {
    pub numbers: HashMap<Uuid, String>,
    pub group_names: HashMap<[u8; 32], String>,
}

impl Lookup for Directory {
    fn number_of(&self, uuid: &Uuid) -> Option<String> {
        self.numbers.get(uuid).cloned()
    }

    fn group_name(&self, master_key: &[u8]) -> Option<String> {
        let key: [u8; 32] = master_key.try_into().ok()?;
        self.group_names.get(&key).cloned()
    }
}

const DIRECTORY_TTL: Duration = Duration::from_secs(60);

impl Account {
    pub fn new(store: SqliteStore, manager: Mgr) -> Self {
        let data = manager.registration_data();
        let aci = data.service_ids.aci;
        let pni = data.service_ids.pni;
        let number = data.phone_number.to_string();
        let device_id = u32::from(manager.device_id());
        Self {
            store,
            manager,
            aci,
            pni,
            number,
            device_id,
            directory: RefCell::new(None),
        }
    }

    /// A handle on the manager (cheap clone sharing websockets and caches).
    pub fn manager(&self) -> Mgr {
        self.manager.clone()
    }

    pub fn local(&self) -> Local<'_> {
        Local::new(&self.store)
    }

    pub fn own_service_id(&self) -> ServiceId {
        Aci::from(self.aci).into()
    }

    pub fn profile_key(&self) -> ProfileKey {
        self.manager.registration_data().profile_key()
    }

    pub async fn contacts(&self) -> Result<Vec<Contact>, RpcError> {
        Ok(self
            .store
            .contacts()
            .await
            .map_err(fail)?
            .filter_map(Result::ok)
            .collect())
    }

    pub async fn contact(&self, uuid: &Uuid) -> Option<Contact> {
        let id: ServiceId = Aci::from(*uuid).into();
        self.store.contact_by_id(&id).await.ok().flatten()
    }

    pub async fn groups(&self) -> Result<Vec<([u8; 32], Group)>, RpcError> {
        Ok(self
            .store
            .groups()
            .await
            .map_err(fail)?
            .filter_map(Result::ok)
            .collect())
    }

    /// A group by its base64 id (as listGroups reports it).
    pub async fn group_by_id(&self, group_id: &str) -> Result<([u8; 32], Group), RpcError> {
        let wanted = normalize_group_id(group_id);
        self.groups()
            .await?
            .into_iter()
            .find(|(key, _)| group_id_from_master_key(key).as_deref() == Some(wanted.as_str()))
            .ok_or_else(|| RpcError::failed(format!("Unknown group: {group_id}")))
    }

    pub fn invalidate_directory(&self) {
        self.directory.borrow_mut().take();
    }

    pub async fn directory(&self) -> Rc<Directory> {
        if let Some((at, dir)) = self.directory.borrow().as_ref() {
            if at.elapsed() < DIRECTORY_TTL {
                return dir.clone();
            }
        }
        let mut dir = Directory::default();
        for c in self.contacts().await.unwrap_or_default() {
            if let Some(p) = &c.phone_number {
                dir.numbers.insert(c.uuid, p.to_string());
            }
        }
        dir.numbers.insert(self.aci, self.number.clone());
        for (key, group) in self.groups().await.unwrap_or_default() {
            dir.group_names.insert(key, group.title);
        }
        let dir = Rc::new(dir);
        *self.directory.borrow_mut() = Some((Instant::now(), dir.clone()));
        dir
    }

    /// Resolves a number (`+…`), an ACI UUID or a `PNI:` service id to a service id.
    pub async fn resolve(&self, id: &str) -> Result<ServiceId, RpcError> {
        let id = id.trim();
        if let Some(sid) = ServiceId::parse_from_service_id_string(id) {
            return Ok(sid);
        }
        if let Ok(uuid) = Uuid::parse_str(id) {
            return Ok(Aci::from(uuid).into());
        }
        if id.starts_with('+') {
            if same_number(id, &self.number) {
                return Ok(self.own_service_id());
            }
            for c in self.contacts().await? {
                if c.phone_number.as_ref().is_some_and(|p| same_number(&p.to_string(), id)) {
                    return Ok(Aci::from(c.uuid).into());
                }
            }
            return Err(RpcError::failed(format!(
                "Unknown recipient {id}: no account with this number is known (number lookup is not supported yet)"
            )));
        }
        Err(RpcError::invalid_params(format!("Invalid recipient: {id}")))
    }

    /// Like [Self::resolve] but requires an ACI (mentions, quotes, reactions need one).
    pub async fn resolve_aci(&self, id: &str) -> Result<Uuid, RpcError> {
        match self.resolve(id).await? {
            ServiceId::Aci(aci) => Ok(aci.into()),
            ServiceId::Pni(_) => Err(RpcError::failed(format!("{id} has no known account id (ACI)"))),
        }
    }

    /// The number of an account if known (own account included).
    pub async fn number_of(&self, uuid: &Uuid) -> Option<String> {
        self.directory().await.number_of(uuid)
    }

    /// The profile of an account from the local cache (no network).
    pub async fn cached_profile(&self, uuid: &Uuid) -> Option<presage::libsignal_service::Profile> {
        let key = if *uuid == self.aci {
            Some(self.profile_key())
        } else {
            let id: ServiceId = Aci::from(*uuid).into();
            self.store.profile_key(&id).await.ok().flatten()
        }?;
        self.store.profile(*uuid, key).await.ok().flatten()
    }

    pub async fn profile_name(&self, uuid: &Uuid) -> Option<String> {
        let profile = self.cached_profile(uuid).await?;
        let name = profile.name?;
        let full = match name.family_name.filter(|f| !f.is_empty()) {
            Some(family) => format!("{} {}", name.given_name, family),
            None => name.given_name,
        };
        (!full.trim().is_empty()).then_some(full)
    }

    /// The file-name key Corvus uses for a person: number if known, else UUID.
    pub async fn key_for(&self, uuid: &Uuid) -> String {
        self.number_of(uuid).await.unwrap_or_else(|| uuid.to_string())
    }
}

/// Group ids arrive as standard base64; tolerate the URL-safe form too.
pub fn normalize_group_id(id: &str) -> String {
    id.trim().replace('-', "+").replace('_', "/")
}

fn same_number(a: &str, b: &str) -> bool {
    let digits = |s: &str| s.chars().filter(|c| c.is_ascii_digit()).collect::<String>();
    !a.is_empty() && digits(a) == digits(b)
}

pub fn now_millis() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or_default()
}
