//! Shared state of the `jsonRpc` process: the data dir, the stdout writer and (when linked) the
//! presage manager with helpers to resolve recipients and groups.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
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
    /// Set by `reconnect` (the Mac woke up, the network came back): a receive loop waiting to
    /// reconnect tries again at once instead of after its backoff.
    pub wake: tokio::sync::Notify,
}

impl Ctx {
    pub fn linked(dir: DataDir, out: Output, account: Account) -> Self {
        Self {
            dir,
            out,
            account: Some(account),
            unavailable: String::new(),
            wake: tokio::sync::Notify::new(),
        }
    }

    /// A process that answers every account method with `reason`.
    pub fn unlinked(dir: DataDir, out: Output, reason: impl Into<String>) -> Self {
        Self {
            dir,
            out,
            account: None,
            unavailable: reason.into(),
            wake: tokio::sync::Notify::new(),
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
    /// Numbers contact discovery (CDSI) found not on Signal, with when it was asked (CDSI is rate
    /// limited). Found accounts are kept in the local store under [DISCOVERED_KEY].
    discovery_misses: RefCell<HashMap<String, Instant>>,
    /// Accounts whose profile was fetched (or tried) this run because nothing else named them.
    profiles_fetched: RefCell<HashSet<Uuid>>,
    /// (requester, timestamp) of messages sent again after a retry request, this run.
    resent: RefCell<HashSet<(String, u64)>>,
    /// When each group's sender key was last handed out ahead of a message (`prepareGroupSend`).
    prepared: RefCell<HashMap<[u8; 32], Instant>>,
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
const DISCOVERED_KEY: &str = "discovered_numbers";
const DISCOVERY_MISS_TTL: Duration = Duration::from_secs(10 * 60);
const PROFILE_FETCH_TIMEOUT: Duration = Duration::from_secs(4);
const PREPARE_INTERVAL: Duration = Duration::from_secs(10 * 60);

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
            discovery_misses: RefCell::new(HashMap::new()),
            profiles_fetched: RefCell::new(HashSet::new()),
            resent: RefCell::new(HashSet::new()),
            prepared: RefCell::new(HashMap::new()),
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
        for (number, aci) in self.discovered().await {
            dir.numbers.entry(aci).or_insert(number);
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
            return match self.discover(id).await? {
                Some(sid) => Ok(sid),
                None => Err(RpcError::failed(format!("{id} is not on Signal"))),
            };
        }
        Err(RpcError::invalid_params(format!("Invalid recipient: {id}")))
    }

    /// Numbers resolved through contact discovery, number → ACI.
    async fn discovered(&self) -> HashMap<String, Uuid> {
        self.local().value(DISCOVERED_KEY).await
    }

    /// Looks a number up with Signal's contact discovery service (CDSI); None when it has no account.
    async fn discover(&self, number: &str) -> Result<Option<ServiceId>, RpcError> {
        let key: String = std::iter::once('+').chain(number.chars().filter(char::is_ascii_digit)).collect();
        let mut known = self.discovered().await;
        if let Some(aci) = known.get(&key) {
            return Ok(Some(Aci::from(*aci).into()));
        }
        if self.discovery_misses.borrow().get(&key).is_some_and(|at| at.elapsed() < DISCOVERY_MISS_TTL) {
            return Ok(None);
        }
        let found = self
            .manager()
            .discover_contacts_by_phone_number([key.as_str()])
            .await
            .map_err(|e| RpcError::failed(format!("Could not look up {number}: {e}")))?
            .into_iter()
            .find_map(|(_, sid)| sid);
        match found {
            Some(ServiceId::Aci(aci)) => {
                known.insert(key, aci.into());
                if let Err(e) = self.local().set_value(DISCOVERED_KEY, &known).await {
                    tracing::warn!("saving discovered number: {e}");
                }
                self.invalidate_directory();
            }
            Some(ServiceId::Pni(_)) => {}
            None => {
                self.discovery_misses.borrow_mut().insert(key, Instant::now());
            }
        }
        Ok(found)
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

    /// The profile name, with the profile fetched (once per run) when it is not cached: a group member who
    /// is not a contact is otherwise shown as a UUID. Bounded, so a slow server does not hold up the caller.
    pub async fn profile_name_fetching(&self, uuid: &Uuid) -> Option<String> {
        if let Some(name) = self.profile_name(uuid).await {
            return Some(name);
        }
        if *uuid == self.aci || !self.profiles_fetched.borrow_mut().insert(*uuid) {
            return None;
        }
        let id: ServiceId = Aci::from(*uuid).into();
        let key = self.store.profile_key(&id).await.ok().flatten()?;
        let mut mgr = self.manager();
        match tokio::time::timeout(PROFILE_FETCH_TIMEOUT, mgr.retrieve_profile_by_uuid(Aci::from(*uuid), key)).await {
            Ok(Ok(_)) => self.profile_name(uuid).await,
            Ok(Err(error)) => {
                tracing::info!(%error, "profile not fetched");
                None
            }
            Err(_) => {
                tracing::info!("profile fetch timed out");
                None
            }
        }
    }

    /// Whether the group's sender key was not handed out ahead of a message in the last minutes.
    pub fn first_prepare(&self, master_key: &[u8; 32]) -> bool {
        let mut prepared = self.prepared.borrow_mut();
        if prepared.get(master_key).is_some_and(|t| t.elapsed() < PREPARE_INTERVAL) {
            return false;
        }
        prepared.insert(*master_key, Instant::now());
        true
    }

    /// Whether the message sent at `timestamp` was not sent again to `requester` yet this run (each of
    /// their devices may ask; one resend reaches them all).
    pub fn first_resend(&self, requester: &ServiceId, timestamp: u64) -> bool {
        self.resent.borrow_mut().insert((requester.service_id_string(), timestamp))
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
