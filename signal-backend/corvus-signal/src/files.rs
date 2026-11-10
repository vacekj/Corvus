//! Data directory layout (see DESIGN.md):
//!
//! ```text
//! DIR/store.db              presage sqlite store (SQLCipher)
//! DIR/attachments/<id>      received attachments
//! DIR/avatars/contact-<id>, profile-<id>, group-<base64url group id>
//! DIR/stickers/<packId>/<stickerId>
//! DIR/accounts.json         [{"number","uuid","deviceId"}]
//! DIR/corvus-signal.log     diagnostic log
//! ```

use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone)]
pub struct DataDir {
    root: PathBuf,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AccountEntry {
    pub number: String,
    pub uuid: String,
    pub device_id: u32,
}

impl DataDir {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    /// `~/Library/Application Support/corvus/signal`
    pub fn default_root() -> PathBuf {
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("."));
        home.join("Library/Application Support/corvus/signal")
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn store(&self) -> PathBuf {
        self.root.join("store.db")
    }

    /// The store a `link` writes to until linking succeeds.
    pub fn linking_store(&self) -> PathBuf {
        self.root.join("store.db.linking")
    }

    pub fn accounts_file(&self) -> PathBuf {
        self.root.join("accounts.json")
    }

    pub fn log_file(&self) -> PathBuf {
        self.root.join("corvus-signal.log")
    }

    pub fn attachments(&self) -> PathBuf {
        self.root.join("attachments")
    }

    pub fn avatars(&self) -> PathBuf {
        self.root.join("avatars")
    }

    pub fn stickers(&self) -> PathBuf {
        self.root.join("stickers")
    }

    pub fn ensure(&self) -> io::Result<()> {
        std::fs::create_dir_all(&self.root)?;
        restrict_permissions(&self.root);
        Ok(())
    }

    /// Path of an attachment by its envelope id; `None` for ids that are not plain file names.
    pub fn attachment(&self, id: &str) -> Option<PathBuf> {
        is_safe_file_name(id).then(|| self.attachments().join(id))
    }

    pub fn contact_avatar(&self, key: &str) -> Option<PathBuf> {
        let name = format!("contact-{key}");
        is_safe_file_name(&name).then(|| self.avatars().join(name))
    }

    pub fn profile_avatar(&self, key: &str) -> Option<PathBuf> {
        let name = format!("profile-{key}");
        is_safe_file_name(&name).then(|| self.avatars().join(name))
    }

    /// `group-<id>` with the base64 group id made URL-safe (`+` → `-`, `/` → `_`, padding kept).
    pub fn group_avatar(&self, group_id: &str) -> Option<PathBuf> {
        let name = format!("group-{}", url_safe_group_id(group_id));
        is_safe_file_name(&name).then(|| self.avatars().join(name))
    }

    pub fn sticker(&self, pack_id_hex: &str, sticker_id: u32) -> Option<PathBuf> {
        (is_hex(pack_id_hex)).then(|| {
            self.stickers()
                .join(pack_id_hex.to_ascii_lowercase())
                .join(sticker_id.to_string())
        })
    }

    pub fn read_accounts(&self) -> Vec<AccountEntry> {
        std::fs::read(self.accounts_file())
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }

    pub fn write_accounts(&self, accounts: &[AccountEntry]) -> io::Result<()> {
        self.ensure()?;
        let json = serde_json::to_vec_pretty(accounts)?;
        write_atomic(&self.accounts_file(), &json)
    }
}

pub fn url_safe_group_id(group_id: &str) -> String {
    group_id.replace('+', "-").replace('/', "_")
}

/// Plain file names only: `^[A-Za-z0-9_.+=-]+$`, not starting with a dot.
pub fn is_safe_file_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 255
        && !name.starts_with('.')
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'-' | b'+' | b'='))
}

fn is_hex(s: &str) -> bool {
    !s.is_empty() && s.len() <= 128 && s.bytes().all(|b| b.is_ascii_hexdigit())
}

/// Writes through a temporary file and a rename, so readers never see a partial file.
pub fn write_atomic(path: &Path, data: &[u8]) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension(format!(
        "tmp-{}-{}",
        std::process::id(),
        rand::random::<u32>()
    ));
    std::fs::write(&tmp, data)?;
    std::fs::rename(&tmp, path).inspect_err(|_| {
        let _ = std::fs::remove_file(&tmp);
    })
}

#[cfg(unix)]
fn restrict_permissions(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700));
}

#[cfg(not(unix))]
fn restrict_permissions(_path: &Path) {}

/// Removes the store (with its WAL/SHM side files).
pub fn remove_store_files(path: &Path) {
    for suffix in ["", "-wal", "-shm", "-journal"] {
        let mut p = path.as_os_str().to_owned();
        p.push(suffix);
        let _ = std::fs::remove_file(PathBuf::from(p));
    }
}

/// Moves a store (with its WAL/SHM side files) to a new path.
pub fn rename_store_files(from: &Path, to: &Path) -> io::Result<()> {
    remove_store_files(to);
    for suffix in ["-wal", "-shm"] {
        let mut f = from.as_os_str().to_owned();
        f.push(suffix);
        let mut t = to.as_os_str().to_owned();
        t.push(suffix);
        let f = PathBuf::from(f);
        if f.exists() {
            std::fs::rename(&f, PathBuf::from(t))?;
        }
    }
    std::fs::rename(from, to)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn safe_names() {
        assert!(is_safe_file_name("AbC_12-x.jpg"));
        assert!(is_safe_file_name("group-abc-_=="));
        assert!(!is_safe_file_name("../etc/passwd"));
        assert!(!is_safe_file_name(".hidden"));
        assert!(!is_safe_file_name("a/b"));
        assert!(!is_safe_file_name(""));
    }

    #[test]
    fn group_avatar_name_is_url_safe() {
        let dir = DataDir::new("/tmp/x");
        let p = dir.group_avatar("ab+/cd==").unwrap();
        assert!(p.ends_with("avatars/group-ab-_cd=="));
    }

    #[test]
    fn accounts_roundtrip() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = DataDir::new(tmp.path());
        assert!(dir.read_accounts().is_empty());
        let entry = AccountEntry {
            number: "+10000000000".into(),
            uuid: "00000000-0000-4000-8000-000000000001".into(),
            device_id: 2,
        };
        dir.write_accounts(std::slice::from_ref(&entry)).unwrap();
        assert_eq!(dir.read_accounts(), vec![entry]);
        let raw: serde_json::Value =
            serde_json::from_slice(&std::fs::read(dir.accounts_file()).unwrap()).unwrap();
        assert_eq!(raw[0]["deviceId"], 2);
    }
}
