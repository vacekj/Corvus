//! Read-only access to a copy of the Signal Desktop database.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use rusqlite::{Connection, OpenFlags};
use serde_json::{Map, Value};

use crate::crypto;

pub struct Conv {
    pub kind: String, // "private" | "group"
    pub e164: String,
    pub service_id: String,
    pub group_id: String,
    pub display: String,
}

pub struct Desktop {
    conn: Connection,
    tmp: PathBuf,
    root: PathBuf,
    pub convs: HashMap<String, Conv>,
    /// messageId -> attachment rows (Signal Desktop 7.4x+ keeps them in `message_attachments`).
    attachment_rows: HashMap<String, Vec<Value>>,
}

impl Drop for Desktop {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.tmp);
    }
}

#[cfg(target_os = "macos")]
fn keychain_password() -> Result<Vec<u8>, String> {
    security_framework::passwords::get_generic_password("Signal Safe Storage", "Signal Key")
        .map_err(|e| format!("could not read \"Signal Safe Storage\" from the keychain: {e}"))
}

#[cfg(not(target_os = "macos"))]
fn keychain_password() -> Result<Vec<u8>, String> {
    Err("encrypted Signal Desktop keys are only supported on macOS".into())
}

fn database_key(root: &Path) -> Result<String, String> {
    let text = fs::read_to_string(root.join("config.json")).map_err(|e| format!("cannot read Signal config.json: {e}"))?;
    let cfg: Value = serde_json::from_str(&text).map_err(|_| "Signal config.json is not JSON")?;
    if let Some(k) = cfg.get("key").and_then(Value::as_str) {
        return Ok(k.to_string());
    }
    let enc = cfg.get("encryptedKey").and_then(Value::as_str).ok_or("Signal config.json has no database key")?;
    let pw = keychain_password()?;
    crypto::safe_storage_decrypt(enc, &pw)
}

fn private_tmp() -> Result<PathBuf, String> {
    let base = std::env::temp_dir();
    for n in 0..100u32 {
        let p = base.join(format!("corvus-signal-import-{}-{n}", std::process::id()));
        if fs::create_dir(&p).is_ok() {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(&p, fs::Permissions::from_mode(0o700)).map_err(|e| e.to_string())?;
            }
            return Ok(p);
        }
    }
    Err("cannot create a temporary folder".into())
}

fn columns(conn: &Connection, table: &str) -> Vec<String> {
    let Ok(mut st) = conn.prepare(&format!("PRAGMA table_info({table})")) else { return vec![] };
    st.query_map([], |r| r.get::<_, String>(1))
        .map(|rows| rows.filter_map(Result::ok).collect())
        .unwrap_or_default()
}

fn str_of(v: &Value, k: &str) -> String {
    v.get(k).and_then(Value::as_str).unwrap_or("").to_string()
}

fn sql_to_json(v: rusqlite::types::ValueRef<'_>) -> Value {
    use rusqlite::types::ValueRef::*;
    match v {
        Null | Blob(_) => Value::Null,
        Integer(i) => i.into(),
        Real(f) => serde_json::Number::from_f64(f).map(Value::Number).unwrap_or(Value::Null),
        Text(t) => String::from_utf8_lossy(t).into_owned().into(),
    }
}

impl Desktop {
    pub fn open(root: &Path) -> Result<Desktop, String> {
        let db = root.join("sql/db.sqlite");
        if !db.exists() {
            return Err(format!("no Signal Desktop database at {}", db.display()));
        }
        let key = database_key(root)?;
        if key.len() != 64 || !key.bytes().all(|c| c.is_ascii_hexdigit()) {
            return Err("unexpected Signal database key format".into());
        }
        // Work on a copy so the running Signal Desktop is never touched.
        let tmp = private_tmp()?;
        for suffix in ["", "-wal", "-shm"] {
            let src = root.join(format!("sql/db.sqlite{suffix}"));
            if src.exists() {
                fs::copy(&src, tmp.join(format!("db.sqlite{suffix}"))).map_err(|e| format!("cannot copy the database: {e}"))?;
            }
        }
        let conn = Connection::open_with_flags(tmp.join("db.sqlite"), OpenFlags::SQLITE_OPEN_READ_WRITE)
            .map_err(|e| format!("cannot open the database copy: {e}"))?;
        conn.execute_batch(&format!("PRAGMA key = \"x'{key}'\";"))
            .map_err(|e| format!("cannot set the database key: {e}"))?;
        conn.query_row("SELECT count(*) FROM sqlite_master", [], |r| r.get::<_, i64>(0))
            .map_err(|_| "the database key did not unlock the Signal database".to_string())?;
        let mut d = Desktop { conn, tmp, root: root.to_path_buf(), convs: HashMap::new(), attachment_rows: HashMap::new() };
        d.load_conversations()?;
        d.load_attachment_rows()?;
        Ok(d)
    }

    fn load_conversations(&mut self) -> Result<(), String> {
        let rows = self.rows_with_json("SELECT * FROM conversations", |_, _| Ok(()))?;
        for j in rows {
            let id = str_of(&j, "id");
            let kind = str_of(&j, "type");
            let mut display = String::new();
            for k in ["nicknameGivenName", "name", "systemGivenName", "profileFullName", "profileName"] {
                let v = str_of(&j, k);
                if !v.is_empty() {
                    display = v;
                    if k == "nicknameGivenName" {
                        let fam = str_of(&j, "nicknameFamilyName");
                        if !fam.is_empty() {
                            display = format!("{display} {fam}");
                        }
                    }
                    break;
                }
            }
            if display.is_empty() && kind == "private" {
                let fam = str_of(&j, "profileFamilyName");
                let given = str_of(&j, "profileName");
                display = format!("{given} {fam}").trim().to_string();
            }
            let mut service_id = str_of(&j, "serviceId");
            if service_id.is_empty() {
                service_id = str_of(&j, "uuid");
            }
            self.convs.insert(
                id,
                Conv { kind, e164: str_of(&j, "e164"), service_id, group_id: str_of(&j, "groupId"), display },
            );
        }
        Ok(())
    }

    fn load_attachment_rows(&mut self) -> Result<(), String> {
        let cols = columns(&self.conn, "message_attachments");
        if cols.is_empty() {
            return Ok(());
        }
        let order = if cols.iter().any(|c| c == "orderInMessage") { " ORDER BY messageId, orderInMessage" } else { "" };
        let mut st = self.conn.prepare(&format!("SELECT * FROM message_attachments{order}")).map_err(|e| e.to_string())?;
        let names: Vec<String> = st.column_names().iter().map(|s| s.to_string()).collect();
        let mut rows = st.query([]).map_err(|e| e.to_string())?;
        while let Some(r) = rows.next().map_err(|e| e.to_string())? {
            let mut o = Map::new();
            for (i, n) in names.iter().enumerate() {
                o.insert(n.clone(), sql_to_json(r.get_ref(i).map_err(|e| e.to_string())?));
            }
            let row = Value::Object(o);
            let mid = str_of(&row, "messageId");
            self.attachment_rows.entry(mid).or_default().push(row);
        }
        Ok(())
    }

    /// Rebuilds the legacy `attachments` / `sticker.data` JSON shape from `message_attachments` rows.
    fn merge_attachment_rows(&self, id: &str, m: &mut Value) {
        let Some(rows) = self.attachment_rows.get(id) else { return };
        let mut atts: Vec<Value> = Vec::new();
        for r in rows {
            let kind = str_of(r, "attachmentType");
            if !kind.is_empty() && kind != "attachment" && kind != "sticker" {
                continue;
            }
            if r.get("editHistoryIndex").is_some_and(|v| !v.is_null() && v.as_i64() != Some(-1)) {
                continue; // attachments of older edit revisions
            }
            let mut a = Map::new();
            for (from, to) in [
                ("contentType", "contentType"),
                ("path", "path"),
                ("localKey", "localKey"),
                ("size", "size"),
                ("fileName", "fileName"),
                ("width", "width"),
                ("height", "height"),
                ("version", "version"),
            ] {
                if let Some(v) = r.get(from).filter(|v| !v.is_null()) {
                    a.insert(to.into(), v.clone());
                }
            }
            for (prefix, field) in [("thumbnail", "thumbnail"), ("screenshot", "screenshot")] {
                let p = str_of(r, &format!("{prefix}Path"));
                if !p.is_empty() {
                    let mut t = Map::new();
                    t.insert("path".into(), p.into());
                    t.insert("localKey".into(), r.get(&format!("{prefix}LocalKey")).cloned().unwrap_or(Value::Null));
                    t.insert("size".into(), r.get(&format!("{prefix}Size")).cloned().unwrap_or(Value::Null));
                    a.insert(field.into(), Value::Object(t));
                }
            }
            if kind == "sticker" {
                if let Some(st) = m.get_mut("sticker").and_then(Value::as_object_mut) {
                    st.insert("data".into(), Value::Object(a));
                }
            } else {
                atts.push(Value::Object(a));
            }
        }
        if !atts.is_empty() {
            let has = m.get("attachments").and_then(Value::as_array).is_some_and(|l| l.iter().any(|a| a.get("path").is_some()));
            if !has {
                m["attachments"] = Value::Array(atts);
            }
        }
    }

    /// Calls `f` for every message (its JSON, with attachment rows merged), ordered by conversation and time.
    pub fn for_each_message(&self, mut f: impl FnMut(&Value) -> Result<(), String>) -> Result<(), String> {
        self.rows_with_json("SELECT * FROM messages ORDER BY conversationId, sent_at", |_, m| {
            let id = str_of(m, "id");
            self.merge_attachment_rows(&id, m);
            f(m)
        })?;
        Ok(())
    }

    /// Runs `sql` and returns (or streams to `each`) every row as its `json` column merged with the
    /// other columns: Signal Desktop moves fields such as body/type/sent_at out of the JSON.
    fn rows_with_json(
        &self,
        sql: &str,
        mut each: impl FnMut(usize, &mut Value) -> Result<(), String>,
    ) -> Result<Vec<Value>, String> {
        let collect = sql.contains("conversations");
        let mut st = self.conn.prepare(sql).map_err(|e| e.to_string())?;
        let names: Vec<String> = st.column_names().iter().map(|s| s.to_string()).collect();
        let mut rows = st.query([]).map_err(|e| e.to_string())?;
        let mut out = Vec::new();
        let mut n = 0;
        while let Some(r) = rows.next().map_err(|e| e.to_string())? {
            let mut obj = Map::new();
            let mut cols = Map::new();
            for (i, name) in names.iter().enumerate() {
                let v = r.get_ref(i).map_err(|e| e.to_string())?;
                if name == "json" {
                    if let rusqlite::types::ValueRef::Text(t) = v {
                        if let Ok(Value::Object(o)) = serde_json::from_slice::<Value>(t) {
                            obj = o;
                        }
                    }
                } else {
                    let j = sql_to_json(v);
                    if !j.is_null() {
                        cols.insert(name.clone(), j);
                    }
                }
            }
            for (k, v) in cols {
                obj.entry(k).or_insert(v);
            }
            let mut v = Value::Object(obj);
            each(n, &mut v)?;
            n += 1;
            if collect {
                out.push(v);
            }
        }
        Ok(out)
    }

    fn locate(&self, rel: &str) -> Option<PathBuf> {
        if rel.is_empty() || rel.contains("..") || rel.starts_with('/') {
            return None;
        }
        for dir in ["attachments.noindex", "stickers.noindex", "drafts.noindex", "downloads.noindex"] {
            let p = self.root.join(dir).join(rel);
            if p.is_file() {
                return Some(p);
            }
        }
        None
    }

    /// Decrypted content of a Signal Desktop file (plaintext legacy files are returned as they are).
    pub fn decrypt_file(&self, rel: &str, local_key: &str, size: i64) -> Result<Vec<u8>, String> {
        let p = self.locate(rel).ok_or("missing file")?;
        let data = fs::read(&p).map_err(|e| e.to_string())?;
        if local_key.is_empty() {
            return Ok(data);
        }
        crypto::decrypt_attachment(&data, local_key, size)
    }

    /// Copies a (still encrypted) attachment file into `dir`; returns the new file name.
    pub fn copy_attachment(&self, rel: &str, dir: &Path) -> Result<String, String> {
        let src = self.locate(rel).ok_or("missing file")?;
        let name: String = rel.chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '_' }).collect();
        let dst = dir.join(&name);
        if !dst.exists() {
            fs::copy(&src, &dst).map_err(|e| e.to_string())?; // clonefile on APFS
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = fs::set_permissions(&dst, fs::Permissions::from_mode(0o600));
            }
        }
        Ok(name)
    }

    pub fn table_columns(&self, table: &str) -> Vec<String> {
        columns(&self.conn, table)
    }
}
