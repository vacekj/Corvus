import CryptoKit
import Foundation

/// The last `listContacts` / `listGroups` answers, so names, group titles and message-request states are
/// right as soon as the history is unlocked instead of after signal-cli has started (seconds for the Java
/// build). Encrypted (AES-GCM) with a key derived from the history secret, like the history itself.
@MainActor
enum RosterCache {
    private static var key: SymmetricKey?
    private static var url: URL { AppPaths.dataDir.appendingPathComponent("roster-cache.bin") }

    /// Called with the secret that just opened the history.
    nonisolated static func deriveKey(from secret: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(secret.utf8)),
                               info: Data("corvus roster cache v1".utf8), outputByteCount: 32)
    }

    static func setKey(_ k: SymmetricKey) {
        key = k
        keyChanged.forEach { $0() }
    }

    /// Other local caches encrypted the same way (the call history) re-read or re-save themselves here.
    static var keyChanged: [@MainActor () -> Void] = []

    /// A key for another local cache, derived from this one (so it changes with the history secret too).
    static func subkey(_ info: String) -> SymmetricKey? {
        key.map { HKDF<SHA256>.deriveKey(inputKeyMaterial: $0, info: Data(info.utf8), outputByteCount: 32) }
    }

    static func forget() {
        key = nil
        try? FileManager.default.removeItem(at: url)
    }

    static func load(account: String) -> (contacts: Any?, groups: Any?)? {
        guard let key, let sealed = try? Data(contentsOf: url), let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: key),
              let o = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any],
              o["account"] as? String == account else { return nil }
        return (o["contacts"], o["groups"])
    }

    static func save(contacts: Any? = nil, groups: Any? = nil, account: String) {
        guard let key, !account.isEmpty else { return }
        var o: [String: Any] = ["account": account]
        if let old = load(account: account) {
            o["contacts"] = old.contacts
            o["groups"] = old.groups
        }
        if let contacts { o["contacts"] = contacts }
        if let groups { o["groups"] = groups }
        guard let plain = try? JSONSerialization.data(withJSONObject: o),
              let sealed = try? AES.GCM.seal(plain, using: key).combined else { return }
        let tmp = url.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: sealed, attributes: [.posixPermissions: 0o600])
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
