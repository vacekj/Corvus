import CHistoryStore
import CryptoKit
import CSQLCipher
import Foundation

/// The chat history as an encrypted SQLite database (SQLCipher): one row per message.
///
/// The app keeps the whole history in memory (`ChatState`); the database is its copy on disk.
/// `load` reads it in one pass straight into `Message` values, and `sync` writes whatever differs
/// between the state and what the file holds: a new message is one inserted row, a deleted or
/// expired one a deleted row (overwritten in the file: `secure_delete`), with no rewrite of the rest.
///
/// A handle is used from one thread at a time (`HistoryWriter` serialises the writes).
public final class HistoryDB: @unchecked Sendable {
    private var db: OpaquePointer?
    /// What the file holds: the state of the last `load` or `sync`. It shares the message arrays with the
    /// live state, so an unchanged chat is recognised without looking at its messages.
    private var baseline: [String: Conversation] = [:]
    private var convIds: [String: Int64] = [:]
    private var stringIds: [String: Int64] = [:]
    private var statements: [String: OpaquePointer] = [:]

    /// A sync that is not `force`d refuses to delete more than this many messages (or any chat): a
    /// routine save never does, so a state that lost its messages by mistake cannot empty the file.
    public static let routineDeleteLimit = 50

    public init() {}
    deinit { close() }

    public var isOpen: Bool { db != nil }

    public static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    /// Removes a database with its journal files.
    public static func remove(_ path: String) {
        for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    // MARK: - Opening

    /// Creates an empty database encrypted with the 32 byte `key`.
    public func create(path: String, key: Data) throws {
        close()
        guard !HistoryDB.exists(path) else { throw HistoryStoreError(code: 3) }
        guard FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw HistoryStoreError(code: 4)
        }
        try connect(path: path, key: key)
        try exec("""
            CREATE TABLE conv(id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE, state TEXT NOT NULL);
            CREATE TABLE str(id INTEGER PRIMARY KEY, s TEXT NOT NULL UNIQUE);
            CREATE TABLE msg(
                id INTEGER PRIMARY KEY,
                conv INTEGER NOT NULL, ts INTEGER NOT NULL, au INTEGER NOT NULL, o INTEGER NOT NULL,
                ot INTEGER NOT NULL, sn INTEGER NOT NULL, rs INTEGER NOT NULL,
                ex INTEGER NOT NULL, es INTEGER NOT NULL,
                x TEXT NOT NULL, rr TEXT, d TEXT);
            CREATE UNIQUE INDEX msg_identity ON msg(conv, ts, au, o);
            PRAGMA user_version = 1;
            """)
    }

    /// Opens an existing database. `wrongPassphrase` if `key` does not decrypt it.
    public func open(path: String, key: Data) throws {
        close()
        guard HistoryDB.exists(path) else { throw HistoryStoreError(code: 4) }
        try connect(path: path, key: key)
        var version: Int64 = 0
        try query("PRAGMA user_version") { version = sqlite3_column_int64($0, 0) }
        guard version == 1 else {
            close()
            throw HistoryStoreError(code: 2)
        }
    }

    private func connect(path: String, key: Data) throws {
        guard key.count == 32 else { throw HistoryStoreError(code: 6) }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw HistoryStoreError(code: 4)
        }
        db = handle
        do {
            // A raw key: no key derivation on every start (the key is random, or unwrapped by Argon2).
            try exec("PRAGMA key = \"x'\(HistoryKey.hex(key))'\"")
            do { try exec("SELECT count(*) FROM sqlite_master") } catch {
                throw HistoryStoreError.wrongPassphrase // SQLITE_NOTADB: the pages do not decrypt
            }
            try exec("""
                PRAGMA journal_mode = WAL;
                PRAGMA synchronous = FULL;
                PRAGMA secure_delete = ON;
                PRAGMA cache_size = -2000;
                PRAGMA temp_store = MEMORY;
                """)
        } catch {
            close()
            throw error
        }
    }

    /// Re-encrypts the whole database with another key.
    public func rekey(_ key: Data) throws {
        guard key.count == 32 else { throw HistoryStoreError(code: 6) }
        try exec("PRAGMA rekey = \"x'\(HistoryKey.hex(key))'\"")
        try exec("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    /// Moves everything from the write-ahead log into the database file and empties the log.
    public func checkpoint() throws { try exec("PRAGMA wal_checkpoint(TRUNCATE)") }

    public func close() {
        for s in statements.values { sqlite3_finalize(s) }
        statements = [:]
        if let db { sqlite3_close(db) }
        db = nil
        baseline = [:]
        convIds = [:]
        stringIds = [:]
    }

    // MARK: - Reading

    /// Milliseconds the last `load` took.
    public private(set) var lastLoadMs = 0

    /// Every chat with its messages, oldest first.
    public func load() throws -> [String: Conversation] {
        let t0 = DispatchTime.now().uptimeNanoseconds
        var state = ChatState()

        // Author keys and sender names repeat for every message of a person: each is one row here and
        // one String shared by all the messages that use it.
        var strings: [String] = [""]
        stringIds = [:]
        try query("SELECT id, s FROM str ORDER BY id") { row in
            let id = Int(sqlite3_column_int64(row, 0))
            let s = Self.text(row, 1)
            if id >= strings.count { strings.append(contentsOf: repeatElement("", count: id - strings.count + 1)) }
            strings[id] = s
            stringIds[s] = Int64(id)
        }

        convIds = [:]
        var keys: [Int64: String] = [:]
        var broken = false
        try query("SELECT id, key, state FROM conv") { row in
            let id = sqlite3_column_int64(row, 0)
            let key = Self.text(row, 1)
            convIds[key] = id
            keys[id] = key
            guard let records = Self.json(row, 2) as? [Any] else { broken = true; return }
            state.ensure(key, title: key, group: key.hasPrefix("g:"))
            for r in records { if let r = r as? JSON { state.applyRecord(r) } }
        }
        if broken { throw HistoryStoreError(code: 2) }

        var lists: [Int64: [Message]] = [:]
        var interned: [String: String] = [:]
        try query("SELECT conv, ts, au, o, ot, sn, rs, ex, es, x, rr, d FROM msg") { row in
            var m = Message()
            m.ts = sqlite3_column_int64(row, 1)
            let au = Int(sqlite3_column_int64(row, 2)), sn = Int(sqlite3_column_int64(row, 5))
            if au < strings.count { m.authorKey = strings[au] }
            m.outgoing = sqlite3_column_int(row, 3) != 0
            m.orderTs = sqlite3_column_int64(row, 4)
            if sn < strings.count { m.sender = strings[sn] }
            m.text = Self.text(row, 9)
            if m.outgoing {
                m.receiptStatus = min(max(Int(sqlite3_column_int(row, 6)), 0), 2)
                if sqlite3_column_type(row, 10) != SQLITE_NULL {
                    m.recipientReceipts = Self.receipts(Self.text(row, 10), &interned)
                }
            }
            let ex = Int(sqlite3_column_int64(row, 7))
            if ex > 0 {
                m.expiresInSeconds = ex
                m.expirationStartMs = sqlite3_column_int64(row, 8)
            }
            if sqlite3_column_type(row, 11) != SQLITE_NULL, let d = Self.json(row, 11) as? JSON {
                if let re = d["re"] as? [String: String] { m.reactions = re }
                Records.applyExtras(&m, d)
            }
            lists[sqlite3_column_int64(row, 0), default: []].append(m)
        }
        for (id, var msgs) in lists {
            guard let key = keys[id], state.convs[key] != nil else { continue }
            // Rows are in the order they were written, which is nearly always the order of the timeline.
            var sorted = true
            for i in msgs.indices.dropFirst() where msgs[i - 1].sortTs > msgs[i].sortTs { sorted = false; break }
            if !sorted {
                msgs = msgs.enumerated().sorted {
                    $0.element.sortTs != $1.element.sortTs ? $0.element.sortTs < $1.element.sortTs : $0.offset < $1.offset
                }.map(\.element)
            }
            // Grown by appending, the list has room for up to as many again: keep one of the exact size.
            if msgs.capacity > msgs.count + msgs.count / 8 { msgs = Array(msgs[...]) }
            state.convs[key]!.msgs = msgs
        }
        state.rebuildPins()
        try? exec("PRAGMA shrink_memory") // the page cache of the full read is not needed for writing
        baseline = state.convs
        lastLoadMs = Int((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
        return state.convs
    }

    public func messageCount() throws -> Int {
        var n = 0
        try query("SELECT count(*) FROM msg") { n = Int(sqlite3_column_int64($0, 0)) }
        return n
    }

    // MARK: - Writing

    public struct SyncSummary: Equatable {
        public var upserted = 0
        public var deleted = 0
        public var chatsWritten = 0
        public var chatsDeleted = 0
    }

    /// Makes the file hold `state`: writes the chats and messages that differ from what it holds and
    /// removes those that are gone. Messages still waiting for their send to be confirmed are left out.
    /// Without `force`, a sync that would remove a chat or many messages throws instead (see
    /// `routineDeleteLimit`); removals the user asked for pass `force`.
    @discardableResult
    public func sync(_ state: ChatState, force: Bool = false) throws -> SyncSummary {
        guard db != nil else { throw HistoryStoreError(code: 6) }
        var target = state.convs
        for (key, c) in target {
            let pending = state.pendingTimestamps(key)
            if !pending.isEmpty { target[key]!.msgs = c.msgs.filter { !pending.contains($0.ts) } }
        }

        // What has to change, before anything is written.
        var removedChats: [String] = []
        var writtenChats: [Conversation] = []
        var upserts: [(String, Message)] = []
        var deletes: [(String, Message)] = []
        for key in baseline.keys where target[key] == nil { removedChats.append(key) }
        for (key, c) in target {
            let old = baseline[key]
            if old == nil || !ChatState.sameSettings(old!, c) { writtenChats.append(c) }
            Self.diff(old?.msgs ?? [], c.msgs) { m, removed in
                if removed { deletes.append((key, m)) } else { upserts.append((key, m)) }
            }
        }
        var summary = SyncSummary()
        summary.upserted = upserts.count
        summary.deleted = deletes.count
        summary.chatsWritten = writtenChats.count
        summary.chatsDeleted = removedChats.count
        if upserts.isEmpty && deletes.isEmpty && writtenChats.isEmpty && removedChats.isEmpty {
            baseline = target
            return summary
        }
        if !force && (!removedChats.isEmpty || deletes.count > HistoryDB.routineDeleteLimit) {
            throw HistoryStoreError(code: HistoryStoreError.refusedCode)
        }

        try exec("BEGIN IMMEDIATE")
        do {
            for key in removedChats {
                guard let id = convIds[key] else { continue }
                try run("DELETE FROM msg WHERE conv = ?1") { sqlite3_bind_int64($0, 1, id) }
                try run("DELETE FROM conv WHERE id = ?1") { sqlite3_bind_int64($0, 1, id) }
            }
            for c in writtenChats {
                let stateJson = try Self.encode(ChatState.settingRecords(c))
                try run("INSERT INTO conv(key, state) VALUES(?1, ?2) ON CONFLICT(key) DO UPDATE SET state = excluded.state") {
                    Self.bind($0, 1, c.key)
                    Self.bind($0, 2, stateJson)
                }
                if convIds[c.key] == nil {
                    try query("SELECT id FROM conv WHERE key = ?1", bind: { Self.bind($0, 1, c.key) }) {
                        self.convIds[c.key] = sqlite3_column_int64($0, 0)
                    }
                }
            }
            for (key, m) in deletes {
                guard let conv = convIds[key], let au = m.authorKey.isEmpty ? 0 : stringIds[m.authorKey] else { continue }
                try run("DELETE FROM msg WHERE conv = ?1 AND ts = ?2 AND au = ?3 AND o = ?4") {
                    sqlite3_bind_int64($0, 1, conv)
                    sqlite3_bind_int64($0, 2, m.ts)
                    sqlite3_bind_int64($0, 3, au)
                    sqlite3_bind_int($0, 4, m.outgoing ? 1 : 0)
                }
            }
            for (key, m) in upserts {
                guard let conv = convIds[key] else { continue }
                try write(conv, key, m)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            // Ids handed out inside the transaction are gone with it.
            try? reloadIds()
            throw error
        }
        for key in removedChats { convIds.removeValue(forKey: key) }
        baseline = target
        // Removed content must not stay readable in the write-ahead log either.
        if !deletes.isEmpty || !removedChats.isEmpty { try? exec("PRAGMA wal_checkpoint(TRUNCATE)") }
        return summary
    }

    private func write(_ conv: Int64, _ key: String, _ m: Message) throws {
        let rec = Records.message(key, m)
        var d = jsonObject(rec["d"])
        // In columns of their own: nearly every message has them, and reading a column needs no JSON.
        for k in ["ot", "rs", "rr", "ex", "es"] { d.removeValue(forKey: k) }
        if !m.reactions.isEmpty && !m.deleted { d["re"] = m.reactions }
        let extras = d.isEmpty ? nil : try Self.encode(d)
        let receipts = m.outgoing && !m.recipientReceipts.isEmpty ? Self.receiptsText(m.recipientReceipts) : nil
        let au = try stringId(m.authorKey), sn = try stringId(m.sender)
        try run("""
            INSERT INTO msg(conv, ts, au, o, ot, sn, rs, ex, es, x, rr, d) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
            ON CONFLICT(conv, ts, au, o) DO UPDATE SET ot = excluded.ot, sn = excluded.sn, rs = excluded.rs,
                ex = excluded.ex, es = excluded.es, x = excluded.x, rr = excluded.rr, d = excluded.d
            """) { s in
            sqlite3_bind_int64(s, 1, conv)
            sqlite3_bind_int64(s, 2, m.ts)
            sqlite3_bind_int64(s, 3, au)
            sqlite3_bind_int(s, 4, m.outgoing ? 1 : 0)
            sqlite3_bind_int64(s, 5, m.orderTs)
            sqlite3_bind_int64(s, 6, sn)
            sqlite3_bind_int(s, 7, Int32(m.outgoing ? min(m.receiptStatus, 2) : 0))
            sqlite3_bind_int64(s, 8, Int64(m.expiresInSeconds))
            sqlite3_bind_int64(s, 9, m.expiresInSeconds > 0 ? m.expirationStartMs : 0)
            Self.bind(s, 10, m.deleted ? "" : m.text)
            if let receipts { Self.bind(s, 11, receipts) } else { sqlite3_bind_null(s, 11) }
            if let extras { Self.bind(s, 12, extras) } else { sqlite3_bind_null(s, 12) }
        }
    }

    private func stringId(_ s: String) throws -> Int64 {
        if s.isEmpty { return 0 }
        if let id = stringIds[s] { return id }
        try run("INSERT INTO str(s) VALUES(?1)") { Self.bind($0, 1, s) }
        let id = sqlite3_last_insert_rowid(db)
        stringIds[s] = id
        return id
    }

    private func reloadIds() throws {
        stringIds = [:]
        convIds = [:]
        try query("SELECT id, s FROM str") { self.stringIds[Self.text($0, 1)] = sqlite3_column_int64($0, 0) }
        try query("SELECT id, key FROM conv") { self.convIds[Self.text($0, 1)] = sqlite3_column_int64($0, 0) }
    }

    /// The messages that differ between two message lists of a chat: `change(m, false)` for a message
    /// to write, `change(m, true)` for one to remove. A message is known by its timestamp, author and
    /// direction. Costs nothing for an untouched list and little for the usual change (one message
    /// added or altered): only the part between the common start and end is compared by identity.
    static func diff(_ old: [Message], _ new: [Message], change: (Message, Bool) -> Void) {
        if old.count == new.count {
            let same = old.withUnsafeBufferPointer { a in new.withUnsafeBufferPointer { a.baseAddress == $0.baseAddress } }
            if same { return }
        }
        var start = 0
        let common = min(old.count, new.count)
        while start < common && old[start] == new[start] { start += 1 }
        var endOld = old.count, endNew = new.count
        while endOld > start && endNew > start && old[endOld - 1] == new[endNew - 1] {
            endOld -= 1
            endNew -= 1
        }
        if start == endOld && start == endNew { return }
        struct Identity: Hashable {
            let ts: Int64
            let author: String
            let outgoing: Bool
        }
        var before: [Identity: Message] = [:]
        for m in old[start..<endOld] { before[Identity(ts: m.ts, author: m.authorKey, outgoing: m.outgoing)] = m }
        for m in new[start..<endNew] {
            let id = Identity(ts: m.ts, author: m.authorKey, outgoing: m.outgoing)
            if let was = before.removeValue(forKey: id) {
                if was != m { change(m, false) }
            } else {
                change(m, false)
            }
        }
        for m in before.values { change(m, true) }
    }

    // MARK: - Receipts column

    // "key \t status \t delivered \t read" per recipient, one per line: every outgoing message has
    // them, and this reads much faster than JSON.
    static func receiptsText(_ receipts: [String: RecipientReceipt]) -> String {
        receipts.keys.sorted().compactMap { k -> String? in
            guard !k.isEmpty, !k.contains("\t"), !k.contains("\n"), let r = receipts[k] else { return nil }
            return "\(k)\t\(min(max(r.status, 0), 2))\t\(r.deliveredAtMs)\t\(r.readAtMs)"
        }.joined(separator: "\n")
    }

    static func receipts(_ text: String, _ interned: inout [String: String]) -> [String: RecipientReceipt] {
        var out: [String: RecipientReceipt] = [:]
        for line in text.utf8.split(separator: UInt8(ascii: "\n")) {
            let f = line.split(separator: UInt8(ascii: "\t"), omittingEmptySubsequences: false)
            guard f.count == 4, !f[0].isEmpty else { continue }
            var key = String(decoding: f[0], as: UTF8.self)
            if let known = interned[key] { key = known } else { interned[key] = key }
            out[key] = RecipientReceipt(status: min(max(Self.int(f[1]), 0), 2),
                                        deliveredAtMs: Int64(Self.int(f[2])), readAtMs: Int64(Self.int(f[3])))
        }
        return out
    }

    private static func int(_ digits: Substring.UTF8View.SubSequence) -> Int {
        var n = 0
        var negative = false
        for b in digits {
            if b == UInt8(ascii: "-") { negative = true; continue }
            guard b >= 48, b <= 57 else { return 0 }
            n = n &* 10 &+ Int(b - 48)
        }
        return negative ? -n : n
    }

    // MARK: - SQLite

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func bind(_ s: OpaquePointer, _ i: Int32, _ text: String) {
        var text = text
        text.withUTF8 { utf8 in
            // An empty buffer may have no address: bind a (non-NULL) empty text all the same.
            _ = utf8.withMemoryRebound(to: CChar.self) { sqlite3_bind_text(s, i, $0.baseAddress ?? UnsafePointer(emptyText), Int32($0.count), transient) }
        }
    }

    private static let emptyText: UnsafeMutablePointer<CChar> = {
        let p = UnsafeMutablePointer<CChar>.allocate(capacity: 1)
        p.pointee = 0
        return p
    }()

    private static func text(_ row: OpaquePointer, _ i: Int32) -> String {
        guard let p = sqlite3_column_text(row, i) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: p, count: Int(sqlite3_column_bytes(row, i))), as: UTF8.self)
    }

    private static func json(_ row: OpaquePointer, _ i: Int32) -> Any? {
        guard let p = sqlite3_column_blob(row, i) else { return nil }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: p), count: Int(sqlite3_column_bytes(row, i)), deallocator: .none)
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func encode(_ obj: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), as: UTF8.self)
    }

    private func failure(_ rc: Int32) -> HistoryStoreError {
        switch rc {
        case SQLITE_NOTADB, SQLITE_CORRUPT: return HistoryStoreError(code: 2)
        default: return HistoryStoreError(code: 4)
        }
    }

    private func exec(_ sql: String) throws {
        let rc = sqlite3_exec(db, sql, nil, nil, nil)
        if rc != SQLITE_OK { throw failure(rc) }
    }

    /// Prepared once per statement text and kept.
    private func statement(_ sql: String) throws -> OpaquePointer {
        if let s = statements[sql] { return s }
        var s: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &s, nil)
        guard rc == SQLITE_OK, let s else { throw failure(rc) }
        statements[sql] = s
        return s
    }

    private func run(_ sql: String, bind: (OpaquePointer) -> Void = { _ in }) throws {
        try query(sql, bind: bind) { _ in }
    }

    private func query(_ sql: String, bind: (OpaquePointer) -> Void = { _ in }, row: (OpaquePointer) -> Void) throws {
        let s = try statement(sql)
        defer {
            sqlite3_reset(s)
            sqlite3_clear_bindings(s)
        }
        bind(s)
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_ROW { row(s) } else if rc == SQLITE_DONE { return } else { throw failure(rc) }
        }
    }
}

extension HistoryStoreError {
    /// A routine save that would have removed a chat or many messages (`HistoryDB.sync`).
    static let refusedCode: Int32 = 100
}

/// The key of the history database and how it is protected.
///
/// * System keychain: the key is derived from the secret kept there; nothing else is stored.
/// * Passphrase: a random key, wrapped under the passphrase (Argon2id, as the former history file
///   did) in a small key file next to the database. Changing the passphrase rewrites only that file.
public enum HistoryKey {
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    public static func random() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    /// The database key for a keychain secret (256 random bits: no slow derivation needed).
    public static func fromKeychainSecret(_ secret: String) -> Data {
        Data(SHA256.hash(data: Data("corvus history database key v1\u{0}".utf8) + Data(secret.utf8)))
    }

    /// Writes the key file: `key` wrapped under `passphrase`.
    public static func writeKeyFile(_ path: String, key: Data, passphrase: String) throws {
        guard key.count == 32 else { throw HistoryStoreError(code: 6) }
        var out = [UInt8](repeating: 0, count: Int(SC_WRAPPED_KEY_LEN))
        let rc = key.withUnsafeBytes { k in
            sc_key_wrap(passphrase, k.bindMemory(to: UInt8.self).baseAddress, &out)
        }
        guard rc == 0 else { throw HistoryStoreError(code: rc) }
        let tmp = path + ".tmp"
        guard FileManager.default.createFile(atPath: tmp, contents: Data(out), attributes: [.posixPermissions: 0o600]) else {
            throw HistoryStoreError(code: 4)
        }
        if rename(tmp, path) != 0 { throw HistoryStoreError(code: 4) }
    }

    /// The key from the key file; `wrongPassphrase` if `passphrase` does not open it.
    public static func readKeyFile(_ path: String, passphrase: String) throws -> Data {
        guard let wrapped = FileManager.default.contents(atPath: path) else { throw HistoryStoreError(code: 4) }
        var key = [UInt8](repeating: 0, count: 32)
        let rc = wrapped.withUnsafeBytes { w in
            sc_key_unwrap(passphrase, w.bindMemory(to: UInt8.self).baseAddress, UInt(w.count), &key)
        }
        guard rc == 0 else { throw HistoryStoreError(code: rc) }
        return Data(key)
    }
}

/// Where the history lives in the data folder.
public struct HistoryFiles: Sendable {
    public var db: String        // the history database
    public var keyFile: String   // passphrase protection: the wrapped database key
    public var legacy: String    // the history file of earlier versions (and of the Qt app)

    public init(directory: URL) {
        db = directory.appendingPathComponent("history.db").path
        keyFile = directory.appendingPathComponent("history.key").path
        legacy = directory.appendingPathComponent("history.corvus").path
    }

    /// The legacy file after its content was moved into the database; removed after `backupDays`.
    public var legacyBackup: String { legacy + ".bak" }
    public static let backupDays = 14.0

    public var exists: Bool { HistoryDB.exists(db) || HistoryStore.exists(legacy) }
}

/// Opens the history with the user's secret: the keychain secret or the passphrase.
public enum HistoryOpener {
    /// Opens the database and returns every chat. An existing history file of an earlier version is
    /// moved into a new database first; without any history, `create` makes an empty one.
    /// Throws `HistoryStoreError` (`wrongPassphrase` if the secret does not fit).
    public static func open(_ db: HistoryDB, files: HistoryFiles, secret: String, keychain: Bool,
                            create: Bool) throws -> [String: Conversation] {
        if HistoryDB.exists(files.db) {
            let key = keychain ? HistoryKey.fromKeychainSecret(secret) : try HistoryKey.readKeyFile(files.keyFile, passphrase: secret)
            try db.open(path: files.db, key: key)
            removeOldBackup(files)
            return try db.load()
        }
        if HistoryStore.exists(files.legacy) {
            return try migrate(db, files: files, secret: secret, keychain: keychain)
        }
        guard create else { throw HistoryStoreError(code: 4) }
        let key = keychain ? HistoryKey.fromKeychainSecret(secret) : HistoryKey.random()
        if !keychain { try HistoryKey.writeKeyFile(files.keyFile, key: key, passphrase: secret) }
        try db.create(path: files.db, key: key)
        return [:]
    }

    /// Moves the history file of an earlier version into a new database. The file is only set aside
    /// (as a backup, for `HistoryFiles.backupDays`) once the database holds every message of it.
    static func migrate(_ db: HistoryDB, files: HistoryFiles, secret: String, keychain: Bool) throws -> [String: Conversation] {
        let legacy = HistoryStore()
        let records = try legacy.open(path: files.legacy, passphrase: secret)
        legacy.close()
        var state = ChatState()
        state.loadHistory(records)
        // Older versions kept small preview copies of pictures in the history; media is shown from the files.
        _ = state.stripAttachmentThumbnails()

        let key = keychain ? HistoryKey.fromKeychainSecret(secret) : HistoryKey.random()
        let building = files.db + ".migrating"
        HistoryDB.remove(building)
        do {
            let fresh = HistoryDB()
            try fresh.create(path: building, key: key)
            try fresh.sync(state, force: true)
            try fresh.checkpoint()
            fresh.close()
            // Read it back before trusting it.
            let check = HistoryDB()
            try check.open(path: building, key: key)
            let loaded = try check.load()
            check.close()
            guard sameMessages(loaded, state.convs) else { throw HistoryStoreError(code: 2) }
        } catch {
            HistoryDB.remove(building)
            throw error
        }
        if !keychain { try HistoryKey.writeKeyFile(files.keyFile, key: key, passphrase: secret) }
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: building + suffix) }
        guard rename(building, files.db) == 0 else {
            HistoryDB.remove(building)
            throw HistoryStoreError(code: 4)
        }
        try? FileManager.default.removeItem(atPath: files.legacyBackup)
        if rename(files.legacy, files.legacyBackup) == 0 {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: files.legacyBackup)
        }
        try db.open(path: files.db, key: key)
        return try db.load()
    }

    /// Every chat of `expected` is there with the same messages (two records of the same message in
    /// an old file count once).
    static func sameMessages(_ loaded: [String: Conversation], _ expected: [String: Conversation]) -> Bool {
        guard Set(loaded.keys) == Set(expected.keys) else { return false }
        for (key, e) in expected {
            guard let c = loaded[key] else { return false }
            if c.msgs.count == e.msgs.count { continue }
            let distinct = Set(e.msgs.map { "\($0.ts)|\($0.authorKey)|\($0.outgoing)" }).count
            if c.msgs.count != distinct { return false }
        }
        return true
    }

    static func removeOldBackup(_ files: HistoryFiles, now: Date = Date()) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: files.legacyBackup),
              let set = attrs[.modificationDate] as? Date,
              now.timeIntervalSince(set) > HistoryFiles.backupDays * 86_400 else { return }
        try? FileManager.default.removeItem(atPath: files.legacyBackup)
    }

    // Changing how the history is protected. The database must be open (`db`); each throws
    // `HistoryStoreError` and leaves the history readable with the old secret if it fails.

    /// Passphrase → another passphrase: only the key file is rewritten.
    public static func changePassphrase(files: HistoryFiles, old: String, new: String) throws {
        let key = try HistoryKey.readKeyFile(files.keyFile, passphrase: old)
        try HistoryKey.writeKeyFile(files.keyFile, key: key, passphrase: new)
    }

    /// Passphrase → keychain: the database is re-encrypted with the key of `newSecret` (already saved in
    /// the keychain by the caller) and the key file is removed.
    public static func protectWithKeychain(_ db: HistoryDB, files: HistoryFiles, passphrase: String, newSecret: String) throws {
        _ = try HistoryKey.readKeyFile(files.keyFile, passphrase: passphrase) // the passphrase must be right
        try db.rekey(HistoryKey.fromKeychainSecret(newSecret))
        try? FileManager.default.removeItem(atPath: files.keyFile)
    }

    /// Keychain → passphrase: the current key is wrapped under the passphrase; the database stays as it is.
    public static func protectWithPassphrase(files: HistoryFiles, keychainSecret: String, passphrase: String) throws {
        try HistoryKey.writeKeyFile(files.keyFile, key: HistoryKey.fromKeychainSecret(keychainSecret), passphrase: passphrase)
    }
}
