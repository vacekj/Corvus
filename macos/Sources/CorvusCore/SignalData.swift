import Foundation

/// The backend's data directory (`corvus-signal --config`, see signal-backend/DESIGN.md) and the files
/// Corvus reads from it directly. This is the only place that knows the layout.
public enum SignalDataDir {
    /// ~/Library/Application Support/corvus/signal
    public static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("corvus/signal", isDirectory: true)
    }

    /// Received attachments, `<id>` as in the envelope.
    public static func attachments(_ dir: URL = root) -> URL { dir.appendingPathComponent("attachments", isDirectory: true) }
    /// `contact-<number|uuid>`, `profile-<number|uuid>`, `group-<URL-safe base64 group id>`.
    public static func avatars(_ dir: URL = root) -> URL { dir.appendingPathComponent("avatars", isDirectory: true) }
    /// `<packId>/<stickerId>`.
    public static func stickers(_ dir: URL = root) -> URL { dir.appendingPathComponent("stickers", isDirectory: true) }
    /// `[{"number", "uuid", "deviceId"}]`.
    public static func accountsFile(_ dir: URL = root) -> URL { dir.appendingPathComponent("accounts.json") }
    /// The backend's encrypted store (SQLCipher, keyed by `SignalStoreKey`).
    public static func storeFile(_ dir: URL = root) -> URL { dir.appendingPathComponent("store.db") }

    /// Whether `id` can be used as a file name inside the attachments directory.
    public static func isSafeAttachmentId(_ id: String) -> Bool {
        !id.isEmpty && !id.hasPrefix(".") && id.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil
    }

    /// The received attachment `id` on disk, or nil when there is no such (readable) file. Until signal-cli's
    /// files are copied over (`SignalCliMigration`), an attachment of the old history is read from signal-cli's
    /// data directory.
    public static func attachmentURL(id: String, dir: URL = root, legacyDir: URL? = SignalCliMigration.legacyDataDir()) -> URL? {
        guard isSafeAttachmentId(id) else { return nil }
        let url = attachments(dir).appendingPathComponent(id)
        if FileManager.default.isReadableFile(atPath: url.path) { return url }
        if let legacyDir {
            let old = attachments(legacyDir).appendingPathComponent(id)
            if FileManager.default.isReadableFile(atPath: old.path) { return old }
        }
        return nil
    }

    /// The device id of `account` (number or UUID) in the backend's accounts.json. 1 is the primary device (the
    /// phone that registered the number); linked devices have higher ids. nil when it cannot be determined.
    public static func deviceId(accountsJSON: Data, account: String) -> Int? {
        guard !account.isEmpty, let o = try? JSONSerialization.jsonObject(with: accountsJSON) else { return nil }
        let list = (o as? [[String: Any]]) ?? ((o as? [String: Any])?["accounts"] as? [[String: Any]]) ?? []
        guard let entry = list.first(where: { ($0["number"] as? String) == account || ($0["uuid"] as? String) == account }),
              let id = (entry["deviceId"] as? NSNumber)?.intValue, id > 0
        else { return nil }
        return id
    }

    public static func deviceId(dataDir: URL = root, account: String) -> Int? {
        guard let data = try? Data(contentsOf: accountsFile(dataDir)) else { return nil }
        return deviceId(accountsJSON: data, account: account)
    }

    public static let primaryDeviceId = 1
}

/// The key of the backend's encrypted store: 32 random bytes as 64 hex characters, created on first use and
/// kept in the login keychain (an item of its own, apart from the history key). It reaches the backend only
/// through its stdin (`--store-key-stdin`), never argv or the environment.
public enum SignalStoreKey {
    static let service = "corvus-signal"
    static let account = "store-key"

    public struct Invalid: Error, LocalizedError {
        public var errorDescription: String? { "The keychain item “\(SignalStoreKey.service)” does not hold a valid store key." }
    }

    /// The store exists but its key is gone: a new key would not open it, and silently starting over would lose
    /// the linked device.
    public struct Missing: Error, LocalizedError {
        public var errorDescription: String? {
            "The keychain item “\(SignalStoreKey.service)” with the key of the Signal store is missing. Restore it, or delete all data and link Corvus again."
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: String?

    public static func isValid(_ key: String) -> Bool {
        key.count == 64 && key.allSatisfy { $0.isHexDigit && $0.isASCII }
    }

    /// The key from the keychain, created there when there is none yet and there is no store in `dataDir`
    /// that an old key encrypted.
    public static func loadOrCreate(dataDir: URL = SignalDataDir.root) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        if let saved = try Keychain.load(service: service, account: account) {
            guard isValid(saved) else { throw Invalid() }
            cached = saved
            return saved
        }
        if FileManager.default.fileExists(atPath: SignalDataDir.storeFile(dataDir).path) { throw Missing() }
        let key = HistoryKeychain.generateSecret()
        try Keychain.save(service: service, account: account, secret: key)
        cached = key
        return key
    }

    /// Removes the key ("Delete all data"); a new store gets a new one.
    public static func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
        try Keychain.clear(service: service, account: account)
    }
}

/// Messages in an existing history refer to attachments by signal-cli's ids. The first time the new backend
/// is used, signal-cli's attachments and avatars are copied (cloned on APFS) into its data directory so old
/// media keeps working. signal-cli's directory is only read, never changed.
public enum SignalCliMigration {
    /// signal-cli's default data directory: $XDG_DATA_HOME/signal-cli, else ~/.local/share/signal-cli.
    public static func legacyDataDir(environment: [String: String] = ProcessInfo.processInfo.environment,
                                     home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("signal-cli", isDirectory: true)
        }
        return home.appendingPathComponent(".local/share/signal-cli", isDirectory: true)
    }

    /// signal-cli has attachments and the new directory has none of them.
    public static func isNeeded(from legacy: URL, to dir: URL) -> Bool {
        let fm = FileManager.default
        let old = SignalDataDir.attachments(legacy), new = SignalDataDir.attachments(dir)
        guard let names = try? fm.contentsOfDirectory(atPath: old.path), !names.isEmpty else { return false }
        return !names.contains { fm.fileExists(atPath: new.appendingPathComponent($0).path) }
    }

    /// Copies the attachments and avatars when `isNeeded`; files already in the new directory are kept.
    /// Returns the number of files copied.
    @discardableResult
    public static func copyFiles(from legacy: URL, to dir: URL) -> Int {
        guard isNeeded(from: legacy, to: dir) else { return 0 }
        var copied = 0
        for sub in [SignalDataDir.attachments, SignalDataDir.avatars] {
            copied += copyFlat(from: sub(legacy), to: sub(dir))
        }
        return copied
    }

    /// Regular files directly inside `from` (no symbolic links, no subdirectories).
    private static func copyFlat(from: URL, to: URL) -> Int {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        else { return 0 }
        try? fm.createDirectory(at: to, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var copied = 0
        for item in items {
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            let target = to.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: target.path) { continue }
            // copyItem clones the file on APFS (no extra space, near instant).
            if (try? fm.copyItem(at: item, to: target)) != nil { copied += 1 }
        }
        return copied
    }
}

/// A Signal TLS proxy (the kind the official apps accept as "https://signal.tube/#<host>"), passed to
/// the backend as `--tls-proxy`.
public enum SignalProxy {
    /// "host", "host:port" or a signal.tube link → "host" / "host:port"; "" for empty input; nil when invalid.
    public static func normalize(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }
        for prefix in ["https://signal.tube/#", "http://signal.tube/#", "sgnl://signal.tube/#", "signal.tube/#"]
        where s.lowercased().hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
            break
        }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return nil }
        let host = String(parts[0])
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !host.isEmpty, host.count <= 253, labels.allSatisfy({ label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }) else { return nil }
        if parts.count == 2 {
            guard let port = Int(parts[1]), (1...65535).contains(port), String(port) == parts[1] else { return nil }
            return "\(host.lowercased()):\(port)"
        }
        return host.lowercased()
    }

    /// The backend's global options for the proxy ([] without one).
    public static func arguments(_ proxy: String) -> [String] {
        guard let p = normalize(proxy), !p.isEmpty else { return [] }
        return ["--tls-proxy", p]
    }
}
