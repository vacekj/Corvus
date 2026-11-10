import Foundation
import XCTest
@testable import CorvusCore

final class AppUpdateTests: XCTestCase {
    private func release(_ tag: String) -> AppUpdate.Release {
        AppUpdate.release(fromGitHub: ["tag_name": tag, "html_url": "https://github.com/example/corvus/releases/tag/\(tag)",
                                       "name": "Build", "body": "Notes", "published_at": "2026-11-01T10:00:00Z"])!
    }

    func testTagsAreUnderstood() {
        XCTAssertEqual(AppUpdate.build(fromTag: "v0.3.0"), .version("0.3.0"))
        XCTAssertEqual(AppUpdate.build(fromTag: "1.2"), .version("1.2"))
        XCTAssertEqual(AppUpdate.build(fromTag: "build-ABCDEF1234567"), .commit("abcdef1234567"))
        XCTAssertEqual(AppUpdate.build(fromTag: "commit-0123456"), .commit("0123456"))
        XCTAssertNil(AppUpdate.build(fromTag: "build-xyz"))
        XCTAssertNil(AppUpdate.build(fromTag: "nightly"))
        XCTAssertNil(AppUpdate.build(fromTag: "v1"))
    }

    func testReleaseParsing() {
        let r = release("v0.3.0")
        XCTAssertEqual(r.displayVersion, "0.3.0")
        XCTAssertEqual(r.notes, "Notes")
        XCTAssertNotNil(r.publishedAt)
        XCTAssertEqual(release("build-0123456789abcdef").displayVersion, "build 0123456")
        // Drafts, pre-releases and non-https links are not offered.
        XCTAssertNil(AppUpdate.release(fromGitHub: ["tag_name": "v1.0", "html_url": "https://x.example/r", "prerelease": true]))
        XCTAssertNil(AppUpdate.release(fromGitHub: ["tag_name": "v1.0", "html_url": "http://x.example/r"]))
        XCTAssertNil(AppUpdate.release(fromGitHub: ["html_url": "https://x.example/r"]))
    }

    func testVerdict() {
        let installed = AppUpdate.Installed(version: "0.2.0", commit: "ABCDEF1234567890")
        XCTAssertEqual(AppUpdate.verdict(installed: installed, latest: release("v0.3.0")), .newer)
        XCTAssertEqual(AppUpdate.verdict(installed: installed, latest: release("v0.2.0")), .upToDate)
        XCTAssertEqual(AppUpdate.verdict(installed: installed, latest: release("v0.1.9")), .upToDate)
        XCTAssertEqual(AppUpdate.verdict(installed: installed, latest: release("build-abcdef1")), .upToDate)
        XCTAssertEqual(AppUpdate.verdict(installed: installed, latest: release("build-1111111")),
                       .compareCommits(base: "abcdef1234567890", head: "1111111"))
        let dev = AppUpdate.Installed(version: "", commit: "")
        XCTAssertEqual(AppUpdate.verdict(installed: dev, latest: release("build-1111111")), .unknown)
        XCTAssertEqual(AppUpdate.verdict(installed: dev, latest: release("v9.0")), .unknown)
        XCTAssertTrue(AppUpdate.isNewer(compareStatus: "ahead"))
        XCTAssertFalse(AppUpdate.isNewer(compareStatus: "behind"))
        XCTAssertFalse(AppUpdate.isNewer(compareStatus: "diverged"))
        XCTAssertFalse(AppUpdate.isNewer(compareStatus: "identical"))
    }

    func testInstalledFromInfoPlist() {
        let i = AppUpdate.Installed(infoDictionary: ["CFBundleShortVersionString": "0.2.0", "CorvusBuildCommit": "0123456789abcdef"])
        XCTAssertEqual(i.displayVersion, "0.2.0 (0123456)")
        // The unreplaced placeholder of a hand-made bundle is not a commit.
        XCTAssertEqual(AppUpdate.Installed(infoDictionary: ["CorvusBuildCommit": "@COMMIT@"]).commit, "")
        XCTAssertEqual(AppUpdate.Installed(infoDictionary: nil).displayVersion, "development build")
    }

    func testVersionComparison() {
        XCTAssertEqual(AppUpdate.compareVersions("0.10.0", "0.9.9"), .orderedDescending)
        XCTAssertEqual(AppUpdate.compareVersions("1.2", "1.2.0"), .orderedSame)
        XCTAssertEqual(AppUpdate.compareVersions("1.2.3-beta", "1.2.4"), .orderedAscending)
    }

    func testCheckSchedule() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(AppUpdate.isCheckDue(last: nil, now: now))
        XCTAssertFalse(AppUpdate.isCheckDue(last: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(AppUpdate.isCheckDue(last: now.addingTimeInterval(-25 * 3600), now: now))
        XCTAssertTrue(AppUpdate.isCheckDue(last: now.addingTimeInterval(3600), now: now)) // clock set back
    }
}

final class ShortcutCatalogTests: XCTestCase {
    func testSectionsAreWellFormed() {
        XCTAssertFalse(ShortcutCatalog.sections.isEmpty)
        for section in ShortcutCatalog.sections {
            XCTAssertFalse(section.entries.isEmpty, section.title)
            var seen = Set<[String]>()
            for e in section.entries {
                XCTAssertFalse(e.action.isEmpty)
                XCTAssertFalse(e.alternatives.isEmpty, e.action)
                for keys in e.alternatives {
                    XCTAssertFalse(keys.isEmpty, e.action)
                    XCTAssertTrue(seen.insert(keys).inserted, "\(section.title): \(keys) listed twice")
                }
            }
        }
    }

    func testListsTheMenuShortcuts() {
        let all = Set(ShortcutCatalog.sections.flatMap(\.entries).flatMap(\.alternatives).map(ShortcutCatalog.text))
        for s in ["⌘K", "⌘N", "⇧⌘N", "⌘F", "⌥⌘F", "⇧⌘M", "⇧⌘S", "⌘/", "⌘,", "⌃ Tab", "⌃⇧ Tab"] {
            XCTAssertTrue(all.contains(s), s)
        }
    }
}

final class CallLogTests: XCTestCase {
    func testAnsweredCallHasDuration() {
        var log = CallLog()
        XCTAssertTrue(log.begin(callId: 7, peerKey: "+100", outgoing: true, at: 1_000))
        XCTAssertFalse(log.begin(callId: 7, peerKey: "+100", outgoing: true, at: 1_100)) // repeated ringing event
        XCTAssertEqual(log.records.first?.outcome, .ongoing)
        XCTAssertTrue(log.connected(callId: 7, at: 5_000))
        let r = log.ended(callId: 7, reason: "remote_hangup", at: 190_000)
        XCTAssertEqual(r?.outcome, .answered)
        XCTAssertEqual(r?.durationSeconds, 185)
        XCTAssertEqual(r?.title, "Outgoing voice call")
        XCTAssertNil(log.ended(callId: 7, reason: "hangup", at: 200_000)) // the first end wins
        XCTAssertEqual(log.records.count, 1)
    }

    func testOutcomes() {
        func outcome(outgoing: Bool, reason: String) -> CallRecord.Outcome? {
            var log = CallLog()
            log.begin(callId: 1, peerKey: "+1", outgoing: outgoing, at: 0)
            return log.ended(callId: 1, reason: reason, at: 30_000)?.outcome
        }
        XCTAssertEqual(outcome(outgoing: false, reason: "ring_timeout"), .missed)
        XCTAssertEqual(outcome(outgoing: false, reason: "remote_hangup"), .missed)
        XCTAssertEqual(outcome(outgoing: false, reason: "busy"), .missed)
        XCTAssertEqual(outcome(outgoing: false, reason: "declined"), .declined)
        XCTAssertEqual(outcome(outgoing: false, reason: "declinedonanotherdevice"), .declined)
        XCTAssertEqual(outcome(outgoing: false, reason: "acceptedonanotherdevice"), .answeredElsewhere)
        XCTAssertEqual(outcome(outgoing: true, reason: "remote_busy"), .unanswered)
        XCTAssertEqual(outcome(outgoing: true, reason: "hangup"), .unanswered)
        XCTAssertEqual(outcome(outgoing: true, reason: "tunnel_spawn_error"), .failed)
    }

    func testNewestFirstFilterAndPersistence() throws {
        var log = CallLog()
        log.begin(callId: 1, peerKey: "+1", outgoing: false, at: 1_000)
        log.ended(callId: 1, reason: "ring_timeout", at: 2_000)
        log.begin(callId: 2, peerKey: "+2", outgoing: true, at: 3_000)
        log.begin(callId: 3, peerKey: "+3", outgoing: false, at: 4_000) // left open (crash)
        XCTAssertEqual(log.records.map(\.callId), [3, 2, 1])
        XCTAssertEqual(log.filtered(missedOnly: true).map(\.callId), [1])

        var decoded = try JSONDecoder().decode(CallLog.self, from: JSONEncoder().encode(log))
        XCTAssertEqual(decoded, log)
        decoded.closeDangling(at: 9_000)
        XCTAssertTrue(decoded.records.allSatisfy { $0.endedMs != nil })
        XCTAssertEqual(decoded.records.first?.outcome, .missed)

        decoded.remove(id: decoded.records[1].id)
        XCTAssertEqual(decoded.records.map(\.callId), [3, 1])
    }

    func testLimit() {
        var log = CallLog()
        for i in 0..<(CallLog.limit + 10) { log.begin(callId: Int64(i), peerKey: "+1", outgoing: true, at: Int64(i)) }
        XCTAssertEqual(log.records.count, CallLog.limit)
        XCTAssertEqual(log.records.first?.callId, Int64(CallLog.limit + 9))
    }

    func testDurationText() {
        XCTAssertEqual(CallRecord.durationText(5), "0:05")
        XCTAssertEqual(CallRecord.durationText(185), "3:05")
        XCTAssertEqual(CallRecord.durationText(3729), "1:02:09")
    }
}

final class NotificationMuteTests: XCTestCase {
    func testMuteEndsAndPersists() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let m = NotificationMute.muted(for: 3600, now: now)
        XCTAssertTrue(m.isMuted(at: now.addingTimeInterval(3599)))
        XCTAssertFalse(m.isMuted(at: now.addingTimeInterval(3601)))
        XCTAssertNotNil(m.label(now: now))
        XCTAssertNil(m.label(now: now.addingTimeInterval(4000)))
        XCTAssertFalse(NotificationMute().isMuted(at: now))

        let forever = NotificationMute.muted(for: nil, now: now)
        XCTAssertTrue(forever.isMuted(at: now.addingTimeInterval(1e9)))
        XCTAssertEqual(forever.label(now: now), "Notifications muted")

        let d = try XCTUnwrap(UserDefaults(suiteName: "corvus-mute-test-\(UUID().uuidString)"))
        XCTAssertEqual(NotificationMute.load(d), NotificationMute())
        forever.save(d)
        XCTAssertEqual(NotificationMute.load(d), forever)
        m.save(d)
        XCTAssertEqual(NotificationMute.load(d).until, m.until)
        NotificationMute().save(d)
        XCTAssertNil(NotificationMute.load(d).until)
    }
}

final class SignalDataTests: XCTestCase {
    private let accounts = Data(#"[{"number":"+10000000001","uuid":"u-1","deviceId":1},{"number":"+10000000002","uuid":"u-2","deviceId":3}]"#.utf8)

    func testDeviceId() {
        XCTAssertEqual(SignalDataDir.deviceId(accountsJSON: accounts, account: "+10000000001"), 1)
        XCTAssertEqual(SignalDataDir.deviceId(accountsJSON: accounts, account: "+10000000002"), 3)
        XCTAssertEqual(SignalDataDir.deviceId(accountsJSON: accounts, account: "u-2"), 3)
        XCTAssertNil(SignalDataDir.deviceId(accountsJSON: accounts, account: "+19999999999"))
        XCTAssertNil(SignalDataDir.deviceId(accountsJSON: accounts, account: ""))
        XCTAssertNil(SignalDataDir.deviceId(accountsJSON: Data("{}".utf8), account: "+10000000001"))
        XCTAssertNil(SignalDataDir.deviceId(accountsJSON: Data(#"[{"number":"+1","deviceId":"2"}]"#.utf8), account: "+1"))
        XCTAssertEqual(SignalDataDir.deviceId(accountsJSON: Data(#"{"accounts":[{"number":"+1","deviceId":2}]}"#.utf8), account: "+1"), 2)
    }

    func testLayout() {
        XCTAssertTrue(SignalDataDir.root.path.hasSuffix("/Library/Application Support/corvus/signal"), SignalDataDir.root.path)
        let dir = URL(fileURLWithPath: "/d", isDirectory: true)
        XCTAssertEqual(SignalDataDir.attachments(dir).path, "/d/attachments")
        XCTAssertEqual(SignalDataDir.avatars(dir).path, "/d/avatars")
        XCTAssertEqual(SignalDataDir.stickers(dir).path, "/d/stickers")
        XCTAssertEqual(SignalDataDir.accountsFile(dir).path, "/d/accounts.json")
    }

    func testLegacyDataDir() {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertEqual(SignalCliMigration.legacyDataDir(environment: [:], home: home).path, "/Users/someone/.local/share/signal-cli")
        XCTAssertEqual(SignalCliMigration.legacyDataDir(environment: ["XDG_DATA_HOME": "/data"], home: home).path, "/data/signal-cli")
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("corvus-data-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testAttachmentURL() throws {
        let root = try tempDir()
        let dir = root.appendingPathComponent("new"), legacy = root.appendingPathComponent("old")
        try write("new", SignalDataDir.attachments(dir).appendingPathComponent("a.jpg"))
        try write("old", SignalDataDir.attachments(legacy).appendingPathComponent("b.jpg"))
        try write("both-old", SignalDataDir.attachments(legacy).appendingPathComponent("a.jpg"))
        XCTAssertEqual(SignalDataDir.attachmentURL(id: "a.jpg", dir: dir, legacyDir: legacy)?.path,
                       SignalDataDir.attachments(dir).appendingPathComponent("a.jpg").path)
        XCTAssertEqual(SignalDataDir.attachmentURL(id: "b.jpg", dir: dir, legacyDir: legacy)?.path,
                       SignalDataDir.attachments(legacy).appendingPathComponent("b.jpg").path)
        XCTAssertNil(SignalDataDir.attachmentURL(id: "b.jpg", dir: dir, legacyDir: nil))
        XCTAssertNil(SignalDataDir.attachmentURL(id: "missing", dir: dir, legacyDir: legacy))
        for bad in ["", ".hidden", "../a.jpg", "x/y", "a b"] {
            XCTAssertNil(SignalDataDir.attachmentURL(id: bad, dir: dir, legacyDir: legacy), bad)
        }
    }

    func testMigrationCopiesOnceAndKeepsTheOldFiles() throws {
        let root = try tempDir()
        let dir = root.appendingPathComponent("new"), legacy = root.appendingPathComponent("old")
        XCTAssertFalse(SignalCliMigration.isNeeded(from: legacy, to: dir)) // no signal-cli data
        try write("a", SignalDataDir.attachments(legacy).appendingPathComponent("a.jpg"))
        try write("b", SignalDataDir.attachments(legacy).appendingPathComponent("b.bin"))
        try write("old avatar", SignalDataDir.avatars(legacy).appendingPathComponent("contact-+1"))
        try write("old own", SignalDataDir.avatars(legacy).appendingPathComponent("profile-+2"))
        try FileManager.default.createDirectory(at: SignalDataDir.attachments(legacy).appendingPathComponent("sub"),
                                                withIntermediateDirectories: true)
        // The backend already wrote a newer picture: it stays.
        try write("new avatar", SignalDataDir.avatars(dir).appendingPathComponent("contact-+1"))

        XCTAssertTrue(SignalCliMigration.isNeeded(from: legacy, to: dir))
        XCTAssertEqual(SignalCliMigration.copyFiles(from: legacy, to: dir), 3)
        func text(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }
        XCTAssertEqual(text(SignalDataDir.attachments(dir).appendingPathComponent("a.jpg")), "a")
        XCTAssertEqual(text(SignalDataDir.attachments(dir).appendingPathComponent("b.bin")), "b")
        XCTAssertEqual(text(SignalDataDir.avatars(dir).appendingPathComponent("contact-+1")), "new avatar")
        XCTAssertEqual(text(SignalDataDir.avatars(dir).appendingPathComponent("profile-+2")), "old own")
        XCTAssertFalse(FileManager.default.fileExists(atPath: SignalDataDir.attachments(dir).appendingPathComponent("sub").path))
        // signal-cli's files are untouched.
        XCTAssertEqual(text(SignalDataDir.attachments(legacy).appendingPathComponent("a.jpg")), "a")
        XCTAssertEqual(text(SignalDataDir.avatars(legacy).appendingPathComponent("contact-+1")), "old avatar")
        // Done: the new directory has the files now.
        XCTAssertFalse(SignalCliMigration.isNeeded(from: legacy, to: dir))
        XCTAssertEqual(SignalCliMigration.copyFiles(from: legacy, to: dir), 0)
    }

    func testProxyNormalization() {
        XCTAssertEqual(SignalProxy.normalize(""), "")
        XCTAssertEqual(SignalProxy.normalize("  Proxy.Example.com "), "proxy.example.com")
        XCTAssertEqual(SignalProxy.normalize("proxy.example.com:443"), "proxy.example.com:443")
        XCTAssertEqual(SignalProxy.normalize("https://signal.tube/#proxy.example.com"), "proxy.example.com")
        XCTAssertEqual(SignalProxy.normalize("sgnl://signal.tube/#proxy.example.com"), "proxy.example.com")
        XCTAssertNil(SignalProxy.normalize("proxy.example.com:0"))
        XCTAssertNil(SignalProxy.normalize("proxy.example.com:99999"))
        XCTAssertNil(SignalProxy.normalize("proxy example.com"))
        XCTAssertNil(SignalProxy.normalize("socks5://proxy.example.com:1080"))
        XCTAssertNil(SignalProxy.normalize("-bad.example.com"))
        XCTAssertEqual(SignalProxy.arguments("proxy.example.com"), ["--tls-proxy", "proxy.example.com"])
        XCTAssertEqual(SignalProxy.arguments(""), [])
        XCTAssertEqual(SignalProxy.arguments("not valid!"), [])
    }
}
