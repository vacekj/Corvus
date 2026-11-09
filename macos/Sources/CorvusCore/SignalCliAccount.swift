import Foundation

/// Facts about the signal-cli account that its JSON-RPC interface does not report.
public enum SignalCliAccountData {
    /// signal-cli's default data directory: $XDG_DATA_HOME/signal-cli, else ~/.local/share/signal-cli.
    public static func defaultDataDir(environment: [String: String] = ProcessInfo.processInfo.environment,
                                      home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("signal-cli", isDirectory: true)
        }
        return home.appendingPathComponent(".local/share/signal-cli", isDirectory: true)
    }

    /// The device id of `account` (number or UUID) from signal-cli's `data/accounts.json` and the account
    /// file it points to. 1 is the primary device (the phone that registered the number); linked devices
    /// have higher ids. nil when it cannot be determined.
    public static func deviceId(accountsJSON: Data, account: String, readAccountFile: (String) -> Data?) -> Int? {
        guard !account.isEmpty,
              let o = (try? JSONSerialization.jsonObject(with: accountsJSON)) as? [String: Any],
              let list = o["accounts"] as? [[String: Any]],
              let entry = list.first(where: { ($0["number"] as? String) == account || ($0["uuid"] as? String) == account }),
              let path = entry["path"] as? String, !path.isEmpty, !path.contains("/"), !path.contains(".."),
              let data = readAccountFile(path),
              let a = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = (a["deviceId"] as? NSNumber)?.intValue, id > 0
        else { return nil }
        return id
    }

    public static func deviceId(dataDir: URL, account: String) -> Int? {
        let data = dataDir.appendingPathComponent("data", isDirectory: true)
        guard let accounts = try? Data(contentsOf: data.appendingPathComponent("accounts.json")) else { return nil }
        return deviceId(accountsJSON: accounts, account: account) { try? Data(contentsOf: data.appendingPathComponent($0)) }
    }

    public static let primaryDeviceId = 1
}

/// A Signal TLS proxy (the kind the official apps accept as "https://signal.tube/#<host>"), passed to
/// signal-cli as `--tls-proxy`.
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

    /// signal-cli's global options for the proxy ([] without one).
    public static func arguments(_ proxy: String) -> [String] {
        guard let p = normalize(proxy), !p.isEmpty else { return [] }
        return ["--tls-proxy", p]
    }
}
