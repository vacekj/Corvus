//! corvus-signal-import: reads the local Signal Desktop database (SQLCipher) and writes the
//! conversation history as Corvus history records, one JSON object per line, to stdout.
//!
//! Attachments stay encrypted: the Signal Desktop attachment files are copied (APFS clones)
//! into `--attachments-dir`, and each record keeps the file name ("ep") together with the
//! per-file key ("lk") inside the encrypted Corvus history. Thumbnails are decrypted and
//! stored inline ("th"), like Corvus does for received media.
//!
//! Usage:
//!   corvus-signal-import --account +NUMBER --attachments-dir DIR [--signal-dir DIR]
//!   corvus-signal-import inspect [--signal-dir DIR]     (schema key statistics, no content)
//!
//! Progress and errors go to stderr. Nothing is written to the Signal Desktop folder; the
//! database is copied to a private temporary folder first.

mod crypto;
mod desktop;

use std::collections::{BTreeMap, HashMap};
use std::io::{self, BufWriter, Write};
use std::path::PathBuf;

use base64::Engine;
use serde_json::{json, Map, Value};

use desktop::{Conv, Desktop};

const B64: base64::engine::GeneralPurpose = base64::engine::general_purpose::STANDARD;

struct Args {
    inspect: bool,
    signal_dir: PathBuf,
    attachments_dir: Option<PathBuf>,
    account: String,
}

fn parse_args() -> Result<Args, String> {
    let mut it = std::env::args().skip(1);
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    let mut a = Args {
        inspect: false,
        signal_dir: home.join("Library/Application Support/Signal"),
        attachments_dir: None,
        account: String::new(),
    };
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "inspect" => a.inspect = true,
            "--signal-dir" => a.signal_dir = it.next().ok_or("--signal-dir needs a value")?.into(),
            "--attachments-dir" => a.attachments_dir = Some(it.next().ok_or("--attachments-dir needs a value")?.into()),
            "--account" => a.account = it.next().ok_or("--account needs a value")?,
            "-h" | "--help" => {
                return Err("usage: corvus-signal-import --account +NUMBER --attachments-dir DIR [--signal-dir DIR]".into())
            }
            other => return Err(format!("unknown argument: {other}")),
        }
    }
    if !a.inspect && (a.account.is_empty() || a.attachments_dir.is_none()) {
        return Err("--account and --attachments-dir are required".into());
    }
    Ok(a)
}

fn main() {
    let args = match parse_args() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(2);
        }
    };
    let result = (|| -> Result<(), String> {
        let db = Desktop::open(&args.signal_dir)?;
        if args.inspect {
            return inspect(&db);
        }
        export(&db, &args)
    })();
    if let Err(e) = result {
        eprintln!("error: {e}");
        std::process::exit(1);
    }
}

/// Key statistics of the JSON columns (names and counts only, never values).
fn inspect(db: &Desktop) -> Result<(), String> {
    let mut keys: BTreeMap<String, usize> = BTreeMap::new();
    let mut types: BTreeMap<String, usize> = BTreeMap::new();
    db.for_each_message(|m| {
        *types.entry(m.get("type").and_then(Value::as_str).unwrap_or("?").to_string()).or_default() += 1;
        collect_keys("", m, &mut keys, 0);
        Ok(())
    })?;
    let tables: BTreeMap<&str, Vec<String>> = ["messages", "conversations", "message_attachments"]
        .into_iter()
        .map(|t| (t, db.table_columns(t)))
        .collect();
    let out = json!({ "types": types, "keys": keys, "columns": tables });
    println!("{}", serde_json::to_string_pretty(&out).unwrap());
    Ok(())
}

fn collect_keys(prefix: &str, v: &Value, keys: &mut BTreeMap<String, usize>, depth: usize) {
    if depth > 3 {
        return;
    }
    match v {
        Value::Object(o) => {
            for (k, child) in o {
                // Map-like objects keyed by ids would explode the statistics.
                let name = if k.len() > 40 { "<id>".to_string() } else { k.clone() };
                let p = if prefix.is_empty() { name } else { format!("{prefix}.{name}") };
                *keys.entry(p.clone()).or_default() += 1;
                collect_keys(&p, child, keys, depth + 1);
            }
        }
        Value::Array(a) => {
            for child in a.iter().take(3) {
                collect_keys(&format!("{prefix}[]"), child, keys, depth + 1);
            }
        }
        _ => {}
    }
}

fn s<'a>(v: &'a Value, k: &str) -> &'a str {
    v.get(k).and_then(Value::as_str).unwrap_or("")
}

fn i(v: &Value, k: &str) -> i64 {
    match v.get(k) {
        Some(Value::Number(n)) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)).unwrap_or(0),
        Some(Value::String(t)) => t.parse().unwrap_or(0),
        _ => 0,
    }
}

fn b(v: &Value, k: &str) -> bool {
    match v.get(k) {
        Some(Value::Bool(x)) => *x,
        Some(Value::Number(n)) => n.as_i64().unwrap_or(0) != 0,
        _ => false,
    }
}

struct Exporter<'a> {
    db: &'a Desktop,
    account: String,
    own_ids: Vec<String>,
    att_dir: PathBuf,
    by_service: HashMap<String, String>,
    copied: usize,
    missing: usize,
}

impl<'a> Exporter<'a> {
    /// Corvus key of a person: phone number when known, else the service id (ACI).
    fn person_key(&self, c: &Conv) -> String {
        if !c.e164.is_empty() {
            c.e164.clone()
        } else {
            c.service_id.clone()
        }
    }

    fn key_for_service(&self, service_id: &str) -> String {
        if service_id.is_empty() {
            return String::new();
        }
        if let Some(k) = self.by_service.get(service_id) {
            return k.clone();
        }
        service_id.to_string()
    }

    fn key_for_conv_id(&self, id: &str) -> String {
        if self.own_ids.iter().any(|o| o == id) {
            return self.account.clone();
        }
        self.db.convs.get(id).map(|c| self.person_key(c)).unwrap_or_default()
    }

    fn author_of(&self, m: &Value) -> String {
        if s(m, "type") == "outgoing" {
            return self.account.clone();
        }
        let sid = s(m, "sourceServiceId");
        if !sid.is_empty() {
            return self.key_for_service(sid);
        }
        let src = s(m, "source");
        if !src.is_empty() {
            return src.to_string();
        }
        String::new()
    }

    fn display_of(&self, author: &str) -> String {
        if let Some(c) = self.db.convs.values().find(|c| self.person_key(c) == author) {
            return c.display.clone();
        }
        String::new()
    }

    /// Copies one encrypted Signal Desktop file and returns the attachment JSON for Corvus.
    fn attachment(&mut self, a: &Value) -> Option<Map<String, Value>> {
        let mut o = Map::new();
        let ct = s(a, "contentType");
        if !ct.is_empty() {
            o.insert("ct".into(), ct.into());
        }
        let name = s(a, "fileName");
        if !name.is_empty() {
            o.insert("fn".into(), name.into());
        }
        let size = i(a, "size");
        if size > 0 {
            o.insert("sz".into(), size.into());
        }
        if i(a, "width") > 0 {
            o.insert("w".into(), i(a, "width").into());
        }
        if i(a, "height") > 0 {
            o.insert("h".into(), i(a, "height").into());
        }
        let path = s(a, "path");
        if !path.is_empty() {
            match self.db.copy_attachment(path, &self.att_dir) {
                Ok(file) => {
                    self.copied += 1;
                    o.insert("ep".into(), file.into());
                    o.insert("lk".into(), s(a, "localKey").into());
                }
                Err(_) => self.missing += 1,
            }
        } else {
            self.missing += 1;
        }
        // Inline preview: Desktop's thumbnail (images and video screenshots), else a small image itself.
        let thumb = a
            .get("thumbnail")
            .and_then(|t| self.db.decrypt_file(s(t, "path"), s(t, "localKey"), i(t, "size")).ok())
            .or_else(|| {
                a.get("screenshot")
                    .and_then(|t| self.db.decrypt_file(s(t, "path"), s(t, "localKey"), i(t, "size")).ok())
            })
            .or_else(|| {
                if ct.starts_with("image/") && size > 0 && size <= 200_000 && !path.is_empty() {
                    self.db.decrypt_file(path, s(a, "localKey"), size).ok()
                } else {
                    None
                }
            });
        if let Some(t) = thumb {
            if !t.is_empty() {
                o.insert("th".into(), B64.encode(t).into());
            }
        }
        Some(o)
    }

    fn message(&mut self, conv: &str, m: &Value, out: &mut dyn Write) -> io::Result<bool> {
        let ts = {
            let t = i(m, "sent_at");
            if t > 0 { t } else { i(m, "timestamp") }
        };
        if ts <= 0 {
            return Ok(false);
        }
        let outgoing = s(m, "type") == "outgoing";
        let author = self.author_of(m);
        let mut d = Map::new();
        let received = i(m, "received_at_ms");
        let order = if received > 0 { received } else { i(m, "serverTimestamp") };
        if order > 0 && order != ts {
            d.insert("ot".into(), order.into());
        }
        let deleted = b(m, "deletedForEveryone");
        if deleted {
            d.insert("dl".into(), true.into());
        }
        let ex = i(m, "expireTimer");
        if ex > 0 {
            d.insert("ex".into(), ex.into());
            d.insert("es".into(), i(m, "expirationStartTimestamp").into());
        }
        let view_once = b(m, "isViewOnce");
        if view_once {
            // Opened, sent or expired View Once media is never imported; for simplicity all of it is
            // imported as consumed (the official clients also never re-show it on a linked device).
            d.insert("vo".into(), true.into());
            d.insert("vv".into(), true.into());
        }
        if !deleted {
            if let Some(q) = m.get("quote").filter(|q| q.is_object()) {
                let qa = {
                    let aci = s(q, "authorAci");
                    if !aci.is_empty() { self.key_for_service(aci) } else { s(q, "author").to_string() }
                };
                let note = q
                    .get("attachments")
                    .and_then(Value::as_array)
                    .and_then(|a| a.first())
                    .map(|a| s(a, "contentType").to_string())
                    .unwrap_or_default();
                d.insert("q".into(), json!({"id": i(q, "id"), "a": qa, "t": s(q, "text"), "n": note}));
            }
            if let Some(st) = m.get("storyReplyContext").filter(|q| q.is_object()) {
                if !d.contains_key("q") {
                    let qa = self.key_for_service(s(st, "authorAci"));
                    d.insert("q".into(), json!({"id": i(st, "messageId").max(0), "a": qa, "t": "Story", "n": "story"}));
                }
            }
            let mut atts: Vec<Value> = Vec::new();
            if !view_once {
                if let Some(list) = m.get("attachments").and_then(Value::as_array) {
                    for a in list {
                        if let Some(o) = self.attachment(a) {
                            atts.push(Value::Object(o));
                        }
                    }
                }
                if let Some(st) = m.get("sticker").filter(|v| v.is_object()) {
                    let mut o = Map::new();
                    o.insert("ct".into(), "image/webp".into());
                    o.insert("fn".into(), format!("signal-sticker:{}:{}.webp", s(st, "packId"), i(st, "stickerId")).into());
                    if let Some(data) = st.get("data") {
                        if let Ok(t) = self.db.decrypt_file(s(data, "path"), s(data, "localKey"), i(data, "size")) {
                            o.insert("th".into(), B64.encode(t).into());
                        }
                    }
                    atts.push(Value::Object(o));
                }
            }
            if !atts.is_empty() {
                d.insert("at".into(), Value::Array(atts));
            }
            if let Some(hist) = m.get("editHistory").and_then(Value::as_array) {
                if hist.len() > 1 {
                    let et = i(m, "editMessageTimestamp");
                    d.insert("ed".into(), json!({"x": s(m, "body"), "et": et, "ec": hist.len() - 1}));
                }
            }
            if let Some(p) = m.get("poll").filter(|v| v.is_object()) {
                if let Some(pl) = self.poll(p) {
                    d.insert("pl".into(), pl);
                }
            }
        }
        let mut text = if deleted { String::new() } else { s(m, "body").to_string() };
        if text.is_empty() && !deleted {
            if let Some(p) = m.get("poll") {
                let q = s(p, "question");
                if !q.is_empty() {
                    text = format!("📊 {q}");
                }
            }
        }
        if text.is_empty() && !deleted {
            // Shared contact cards: Corvus has no contact-card view, so they become text.
            if let Some(cards) = m.get("contact").and_then(Value::as_array).filter(|a| !a.is_empty()) {
                let lines: Vec<String> = cards.iter().map(contact_card_text).collect();
                text = lines.join("\n");
            }
        }
        if text.is_empty() && !d.contains_key("at") && !d.contains_key("dl") && !d.contains_key("pl") && !view_once {
            if std::env::var_os("CORVUS_IMPORT_DEBUG").is_some() {
                let keys: Vec<&String> = m.as_object().map(|o| o.keys().collect()).unwrap_or_default();
                eprintln!("skip-empty {:?} contact={} erased={} vo={} flags={} hasAtt={}", keys,
                    m.get("contact").and_then(Value::as_array).map(|a| a.len()).unwrap_or(0),
                    i(m, "isErased"), i(m, "isViewOnce"), i(m, "flags"), i(m, "hasAttachments"));
            }
            return Ok(false); // nothing to show (e.g. an empty reaction carrier)
        }
        let sender = if outgoing { String::new() } else { self.display_of(&author) };
        let mut rec = json!({"t": "m", "c": conv, "ts": ts, "s": sender, "x": text, "o": outgoing, "au": author});
        if !d.is_empty() {
            rec["d"] = Value::Object(d);
        }
        writeln!(out, "{}", rec)?;

        // Reactions on this message.
        if !deleted {
            if let Some(list) = m.get("reactions").and_then(Value::as_array) {
                for r in list {
                    let emoji = s(r, "emoji");
                    let by = self.key_for_conv_id(s(r, "fromId"));
                    if emoji.is_empty() || by.is_empty() || b(r, "remove") {
                        continue;
                    }
                    let rec = json!({"t": "r", "c": conv, "ts": ts, "au": author, "by": by, "e": emoji});
                    writeln!(out, "{}", rec)?;
                }
            }
        }
        Ok(true)
    }

    fn poll(&self, p: &Value) -> Option<Value> {
        let question = s(p, "question");
        let options: Vec<String> = p
            .get("options")
            .and_then(Value::as_array)?
            .iter()
            .map(|o| o.as_str().map(str::to_string).unwrap_or_else(|| s(o, "text").to_string()))
            .collect();
        if question.is_empty() || options.len() < 2 {
            return None;
        }
        let mut votes = Map::new();
        let mut counts = Map::new();
        if let Some(vs) = p.get("votes").and_then(Value::as_array) {
            for v in vs {
                let voter = {
                    let id = s(v, "fromConversationId");
                    if !id.is_empty() { self.key_for_conv_id(id) } else { self.key_for_service(s(v, "fromAci")) }
                };
                if voter.is_empty() {
                    continue;
                }
                votes.insert(voter.clone(), v.get("optionIndexes").cloned().unwrap_or(json!([])));
                counts.insert(voter, i(v, "voteCount").into());
            }
        }
        let multi = p.get("allowMultiple").and_then(Value::as_bool).unwrap_or(true);
        let ended = i(p, "terminatedAt") > 0 || b(p, "terminated") || b(p, "ended");
        Some(json!({"q": question, "o": options, "m": multi, "e": ended, "v": votes, "n": counts}))
    }
}

fn contact_card_text(c: &Value) -> String {
    let name = c.get("name").map(|n| {
        let dn = s(n, "displayName");
        if !dn.is_empty() { dn.to_string() } else { format!("{} {}", s(n, "givenName"), s(n, "familyName")).trim().to_string() }
    }).unwrap_or_default();
    let mut parts = vec![if name.is_empty() { "Contact".to_string() } else { name }];
    for field in ["number", "email"] {
        if let Some(list) = c.get(field).and_then(Value::as_array) {
            parts.extend(list.iter().map(|v| s(v, "value").to_string()).filter(|v| !v.is_empty()));
        }
    }
    format!("👤 {}", parts.join(" · "))
}

fn export(db: &Desktop, args: &Args) -> Result<(), String> {
    let att_dir = args.attachments_dir.clone().unwrap();
    std::fs::create_dir_all(&att_dir).map_err(|e| format!("cannot create {}: {e}", att_dir.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&att_dir, std::fs::Permissions::from_mode(0o700));
    }
    let mut ex = Exporter {
        db,
        account: args.account.clone(),
        own_ids: Vec::new(),
        att_dir,
        by_service: HashMap::new(),
        copied: 0,
        missing: 0,
    };
    for (id, c) in &db.convs {
        if c.kind == "private" {
            if !c.service_id.is_empty() {
                ex.by_service.insert(c.service_id.clone(), ex.person_key(c));
            }
            if !c.e164.is_empty() && c.e164 == args.account {
                ex.own_ids.push(id.clone());
            }
        }
    }
    let stdout = io::stdout();
    let mut out = BufWriter::new(stdout.lock());

    // Conversation names (Corvus applies them only where it knows no name yet).
    for c in db.convs.values() {
        let key = match c.kind.as_str() {
            "group" if !c.group_id.is_empty() => format!("g:{}", c.group_id),
            "private" => ex.person_key(c),
            _ => continue,
        };
        if key.is_empty() || key == args.account || c.display.is_empty() {
            continue;
        }
        let rec = json!({"t": "n", "c": key, "n": c.display});
        writeln!(out, "{}", rec).map_err(|e| e.to_string())?;
    }

    let mut n = 0usize;
    let mut kept = 0usize;
    db.for_each_message(|m| {
        n += 1;
        if n % 5000 == 0 {
            eprintln!("progress {n}");
        }
        let t = s(m, "type");
        if t != "incoming" && t != "outgoing" {
            return Ok(());
        }
        if m.get("storyId").is_some_and(|v| !v.is_null()) && m.get("storyReplyContext").is_none() {
            if std::env::var_os("CORVUS_IMPORT_DEBUG").is_some() { eprintln!("skip-story"); }
            return Ok(());
        }
        let Some(c) = db.convs.get(s(m, "conversationId")) else { return Ok(()) };
        let key = match c.kind.as_str() {
            "group" if !c.group_id.is_empty() => format!("g:{}", c.group_id),
            "private" => ex.person_key(c),
            _ => return Ok(()),
        };
        if key.is_empty() {
            return Ok(());
        }
        if ex.message(&key, m, &mut out).map_err(|e| e.to_string())? {
            kept += 1;
        }
        Ok(())
    })?;
    out.flush().map_err(|e| e.to_string())?;
    eprintln!("done messages={kept} scanned={n} attachments={} unavailable={}", ex.copied, ex.missing);
    Ok(())
}
