import CorvusCore
import CryptoKit
import Foundation

/// The chat list as it was when the app last ran, shown the moment the window opens while the full
/// history is still being unlocked (Argon2 and ~100k records take about a second). Only with keychain
/// protection: the key comes from the same secret, without asking anything. Encrypted (AES-GCM) with a
/// key derived from it like the roster cache, and replaced by the real history as soon as that is loaded.
@MainActor
enum LaunchSnapshot {
    static let recentChats = 60
    static let messagesPerChat = 40

    private static var url: URL { AppPaths.dataDir.appendingPathComponent("launch-snapshot.bin") }
    private static func key() -> SymmetricKey? { RosterCache.subkey("corvus launch snapshot v1") }

    /// The snapshot records for `account`, or nil (none, other account, other key, damaged).
    static func load(account: String) -> [JSON]? {
        guard !account.isEmpty, let key = key(), let sealed = try? Data(contentsOf: url),
              let box = try? AES.GCM.SealedBox(combined: sealed), let plain = try? AES.GCM.open(box, using: key),
              let o = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any],
              o["account"] as? String == account, let records = o["records"] as? [Any] else { return nil }
        return records.compactMap { $0 as? JSON }
    }

    /// Written off the main thread from a copy of the state.
    static func save(_ state: ChatState, account: String, wait: Bool = false) {
        guard !account.isEmpty, let key = key() else { return }
        let box = UncheckedBox(state), url = url
        let write = {
            let o: [String: Any] = ["account": account,
                                    "records": box.value.snapshotRecords(recentChats: recentChats, messages: messagesPerChat)]
            guard let plain = try? JSONSerialization.data(withJSONObject: o),
                  let sealed = try? AES.GCM.seal(plain, using: key).combined else { return }
            let tmp = url.appendingPathExtension("tmp")
            FileManager.default.createFile(atPath: tmp.path, contents: sealed, attributes: [.posixPermissions: 0o600])
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
        }
        if wait { write() } else { DispatchQueue.global(qos: .utility).async(execute: write) }
    }

    static func forget() { try? FileManager.default.removeItem(at: url) }
}

/// Hands a value that is not Sendable (JSON, ChatState) to another thread that owns it from then on.
final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
