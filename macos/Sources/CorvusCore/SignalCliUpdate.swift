import Foundation

/// Automatic signal-cli updates: which release to fetch and where a self-managed install lives.
/// A self-managed install is `<root>/signal-cli-<version>/bin/signal-cli` (the layout of the release
/// archive); an update unpacks the new archive next to it and switches to it.
public enum SignalCliUpdate {
    public struct Release: Equatable {
        public var version: String
        public var archiveURL: URL
        public var sha256: String       // lowercase hex, from the release asset's digest
    }

    /// The JVM archive ("signal-cli-<version>.tar.gz") of a GitHub `releases/latest` answer, with its
    /// SHA-256 digest. Nil without one: an archive that cannot be checked is not installed.
    public static func release(fromGitHub o: [String: Any]) -> Release? {
        var version = (o["tag_name"] as? String) ?? ""
        if version.hasPrefix("v") { version.removeFirst() }
        guard isVersion(version), (o["draft"] as? Bool) != true, (o["prerelease"] as? Bool) != true else { return nil }
        let name = "signal-cli-\(version).tar.gz"
        for case let a as [String: Any] in (o["assets"] as? [Any]) ?? [] where (a["name"] as? String) == name {
            guard let digest = a["digest"] as? String, digest.hasPrefix("sha256:"),
                  let url = URL(string: (a["browser_download_url"] as? String) ?? ""),
                  url.scheme == "https", url.host == "github.com" else { return nil }
            let hex = digest.dropFirst(7).lowercased()
            guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
            return Release(version: version, archiveURL: url, sha256: String(hex))
        }
        return nil
    }

    /// "0.14.10" (digits and dots only: it becomes part of a folder name).
    public static func isVersion(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 20 && s.first!.isNumber && s.allSatisfy { $0.isNumber || $0 == "." }
            && !s.contains("..") && !s.hasSuffix(".")
    }

    /// For `<root>/signal-cli-<version>/bin/signal-cli`: the root folder and the version.
    public static func managedInstall(_ executable: String) -> (root: URL, version: String)? {
        let exe = URL(fileURLWithPath: executable).standardizedFileURL
        let bin = exe.deletingLastPathComponent(), dir = bin.deletingLastPathComponent()
        guard exe.lastPathComponent == "signal-cli", bin.lastPathComponent == "bin",
              dir.lastPathComponent.hasPrefix("signal-cli-") else { return nil }
        let version = String(dir.lastPathComponent.dropFirst("signal-cli-".count))
        guard isVersion(version) else { return nil }
        return (dir.deletingLastPathComponent(), version)
    }

    public static func executable(root: URL, version: String) -> URL {
        root.appendingPathComponent("signal-cli-\(version)/bin/signal-cli")
    }

    /// Homebrew's `brew` for a signal-cli installed by Homebrew, else nil.
    public static func homebrew(_ executable: String) -> String? {
        for prefix in ["/opt/homebrew", "/usr/local"] where executable.hasPrefix(prefix + "/") {
            let real = (try? FileManager.default.destinationOfSymbolicLink(atPath: executable)) ?? executable
            guard executable.hasPrefix(prefix + "/Cellar/") || real.contains("Cellar/signal-cli/") else { continue }
            return prefix + "/bin/brew"
        }
        return nil
    }

    /// Old versions to delete after switching to `current`: all but the current and the one before it.
    public static func obsoleteVersions(_ installed: [String], current: String, previous: String) -> [String] {
        installed.filter { $0 != current && $0 != previous && isVersion($0) }
    }
}
