import Foundation

/// Corvus's own update check against the GitHub releases of `repository`. Nothing is installed: the app
/// only tells the user that a newer build exists and links to its release page.
///
/// Releases are tagged either with a version ("v0.3.0") or per commit ("build-<sha>", as the release
/// workflow does). A version is compared numerically; a commit is compared with the commit the running
/// build was made from (`CorvusBuildCommit` in Info.plist), asking GitHub's compare API when they differ.
public enum AppUpdate {
    /// The repository whose releases are checked ("owner/name").
    public static let repository = "vacekj/Corvus"
    /// Automatic checks run at most this often.
    public static let checkInterval: TimeInterval = 24 * 3600

    public enum Build: Equatable, Sendable {
        case version(String)    // "0.3.0"
        case commit(String)     // full or abbreviated lowercase hex
    }

    public struct Release: Equatable, Sendable {
        public var tag: String
        public var build: Build?
        public var name: String
        public var notes: String
        public var url: URL
        public var publishedAt: Date?

        public init(tag: String, build: Build?, name: String, notes: String, url: URL, publishedAt: Date?) {
            self.tag = tag
            self.build = build
            self.name = name
            self.notes = notes
            self.url = url
            self.publishedAt = publishedAt
        }

        /// "0.3.0" or "build 1a2b3c4".
        public var displayVersion: String {
            switch build {
            case .version(let v): return v
            case .commit(let c): return "build " + AppUpdate.shortCommit(c)
            case nil: return tag
            }
        }
    }

    /// What the running app is.
    public struct Installed: Equatable, Sendable {
        public var version: String
        public var commit: String

        public init(version: String, commit: String) {
            self.version = version
            self.commit = commit.lowercased()
        }

        /// From an Info.plist dictionary (`CFBundleShortVersionString`, `CorvusBuildCommit`).
        public init(infoDictionary d: [String: Any]?) {
            let commit = (d?["CorvusBuildCommit"] as? String) ?? ""
            self.init(version: (d?["CFBundleShortVersionString"] as? String) ?? "",
                      commit: isCommit(commit) ? commit : "")
        }

        public var displayVersion: String {
            let v = version.isEmpty ? "development build" : version
            return commit.isEmpty ? v : "\(v) (\(AppUpdate.shortCommit(commit)))"
        }
    }

    public enum Verdict: Equatable, Sendable {
        case upToDate
        case newer
        /// The running build does not say which commit it is, so a per-commit release cannot be compared.
        case unknown
        /// Ask GitHub whether `head` is ahead of `base` (see `isNewer(compareStatus:)`).
        case compareCommits(base: String, head: String)
    }

    public static func isCommit(_ s: String) -> Bool {
        (7...40).contains(s.count) && s.allSatisfy(\.isHexDigit)
    }

    public static func shortCommit(_ c: String) -> String { String(c.prefix(7)) }

    /// "v1.2.3" / "1.2.3" → version; "build-<sha>" / "commit-<sha>" → commit; anything else → nil.
    public static func build(fromTag tag: String) -> Build? {
        let t = tag.trimmingCharacters(in: .whitespaces)
        for prefix in ["build-", "commit-"] where t.lowercased().hasPrefix(prefix) {
            let sha = String(t.dropFirst(prefix.count)).lowercased()
            return isCommit(sha) ? .commit(sha) : nil
        }
        let v = t.hasPrefix("v") || t.hasPrefix("V") ? String(t.dropFirst()) : t
        let parts = v.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.first!.isNumber }) else { return nil }
        return .version(v)
    }

    /// The `releases/latest` answer of the GitHub API. Drafts and pre-releases are not offered.
    public static func release(fromGitHub o: [String: Any]) -> Release? {
        guard let tag = o["tag_name"] as? String, !tag.isEmpty,
              let urlString = o["html_url"] as? String, let url = URL(string: urlString), url.scheme == "https"
        else { return nil }
        if o["draft"] as? Bool == true || o["prerelease"] as? Bool == true { return nil }
        let published = (o["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let name = (o["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let notes = (o["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Release(tag: tag, build: build(fromTag: tag), name: name.isEmpty ? tag : name, notes: notes,
                       url: url, publishedAt: published)
    }

    public static func verdict(installed: Installed, latest: Release) -> Verdict {
        switch latest.build {
        case .version(let v):
            guard !installed.version.isEmpty else { return .unknown }
            return compareVersions(v, installed.version) == .orderedDescending ? .newer : .upToDate
        case .commit(let c):
            let mine = installed.commit
            guard !mine.isEmpty else { return .unknown }
            if mine.hasPrefix(c) || c.hasPrefix(mine) { return .upToDate }
            return .compareCommits(base: mine, head: c)
        case nil:
            return .unknown
        }
    }

    /// GitHub's `compare/base...head` status: "ahead" means the release has commits the running build lacks
    /// and none the other way. "behind" / "identical" are not updates; "diverged" (another branch) is not either.
    public static func isNewer(compareStatus: String) -> Bool { compareStatus == "ahead" }

    /// Numeric dotted versions; a missing component counts as 0, a suffix ("1.2.3-beta") is ignored.
    public static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    public static func isCheckDue(last: Date?, now: Date, interval: TimeInterval = checkInterval) -> Bool {
        guard let last else { return true }
        // A clock set back must not stop the checks for good.
        return now.timeIntervalSince(last) >= interval || last > now
    }
}
