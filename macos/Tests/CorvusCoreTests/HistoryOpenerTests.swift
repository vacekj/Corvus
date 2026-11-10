import XCTest
@testable import CorvusCore

final class HistoryOpenerTests: XCTestCase {
    private var dir: URL!
    private var files: HistoryFiles { HistoryFiles(directory: dir) }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("corvus-open-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func state() -> ChatState {
        var s = ChatState()
        for ts in Int64(1)...40 {
            var m = Message()
            m.ts = ts
            m.orderTs = ts
            m.text = "message \(ts)"
            m.authorKey = ts % 2 == 0 ? "+491" : "+492"
            m.sender = "Sender \(ts % 2)"
            if ts % 5 == 0 { m.reactions["+490"] = "👍" }
            if ts == 7 {
                var a = Attachment()
                a.id = "a7"
                a.contentType = "image/png"
                a.thumb = Data([1, 2, 3]) // previews of old versions are dropped on the way
                m.attachments = [a]
            }
            s.ensure(ts % 3 == 0 ? "g:grp" : "+491", title: "t", group: ts % 3 == 0)
            s.convs[ts % 3 == 0 ? "g:grp" : "+491"]!.msgs.append(m)
        }
        s.convs["+491"]!.storedName = "Ann"
        s.convs["g:grp"]!.pinned = true
        return s
    }

    private func writeLegacy(_ s: ChatState, passphrase: String) throws {
        let store = HistoryStore()
        try store.create(path: files.legacy, passphrase: passphrase)
        try store.rewrite(s.allRecords())
        // A record of the same message twice, as old files can have: it counts once.
        try store.append(Records.message("+491", s.convs["+491"]!.msgs[0]))
        store.close()
    }

    private func expected(_ s: ChatState) -> ChatState {
        var e = ChatState()
        e.loadHistory(s.allRecords())
        _ = e.stripAttachmentThumbnails()
        return e
    }

    private func assertSame(_ loaded: [String: Conversation], _ e: ChatState, line: UInt = #line) {
        XCTAssertEqual(Set(loaded.keys), Set(e.convs.keys), line: line)
        for (k, c) in e.convs {
            XCTAssertEqual(loaded[k]?.msgs, c.msgs, line: line)
            XCTAssertEqual(loaded[k]?.storedName, c.storedName, line: line)
            XCTAssertEqual(loaded[k]?.pinned, c.pinned, line: line)
        }
    }

    func testHistoryFileOfAnEarlierVersionIsMovedOnceWithKeychainProtection() throws {
        let s = state()
        try writeLegacy(s, passphrase: "keychain secret")
        XCTAssertTrue(files.exists)

        let db = HistoryDB()
        let loaded = try HistoryOpener.open(db, files: files, secret: "keychain secret", keychain: true, create: false)
        assertSame(loaded, expected(s))
        db.close()
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: files.db))
        XCTAssertFalse(fm.fileExists(atPath: files.legacy))
        XCTAssertTrue(fm.fileExists(atPath: files.legacyBackup))
        XCTAssertFalse(fm.fileExists(atPath: files.keyFile)) // the key comes from the keychain secret
        XCTAssertFalse(fm.fileExists(atPath: files.db + ".migrating"))

        // From now on the database is opened; another secret does not fit.
        let again = HistoryDB()
        assertSame(try HistoryOpener.open(again, files: files, secret: "keychain secret", keychain: true, create: false), expected(s))
        again.close()
        XCTAssertThrowsError(try HistoryOpener.open(HistoryDB(), files: files, secret: "other", keychain: true, create: false)) {
            XCTAssertEqual($0 as? HistoryStoreError, .wrongPassphrase)
        }
    }

    func testWrongSecretLeavesTheHistoryFileAlone() throws {
        try writeLegacy(state(), passphrase: "right")
        XCTAssertThrowsError(try HistoryOpener.open(HistoryDB(), files: files, secret: "wrong", keychain: false, create: false)) {
            XCTAssertEqual($0 as? HistoryStoreError, .wrongPassphrase)
        }
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: files.legacy))
        XCTAssertFalse(fm.fileExists(atPath: files.db))
        XCTAssertFalse(fm.fileExists(atPath: files.keyFile))
    }

    func testPassphraseProtectionAndItsChanges() throws {
        let s = state()
        try writeLegacy(s, passphrase: "first pass")
        let db = HistoryDB()
        _ = try HistoryOpener.open(db, files: files, secret: "first pass", keychain: false, create: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.keyFile))

        try HistoryOpener.changePassphrase(files: files, old: "first pass", new: "second pass")
        XCTAssertThrowsError(try HistoryOpener.changePassphrase(files: files, old: "first pass", new: "x"))
        db.close()
        let second = HistoryDB()
        assertSame(try HistoryOpener.open(second, files: files, secret: "second pass", keychain: false, create: false), expected(s))

        // Passphrase → keychain: the wrong passphrase changes nothing.
        XCTAssertThrowsError(try HistoryOpener.protectWithKeychain(second, files: files, passphrase: "nope", newSecret: "kc"))
        try HistoryOpener.protectWithKeychain(second, files: files, passphrase: "second pass", newSecret: "kc")
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.keyFile))
        second.close()
        let third = HistoryDB()
        assertSame(try HistoryOpener.open(third, files: files, secret: "kc", keychain: true, create: false), expected(s))

        // Keychain → passphrase.
        try HistoryOpener.protectWithPassphrase(files: files, keychainSecret: "kc", passphrase: "third pass")
        third.close()
        let fourth = HistoryDB()
        assertSame(try HistoryOpener.open(fourth, files: files, secret: "third pass", keychain: false, create: false), expected(s))
    }

    func testNewHistory() throws {
        XCTAssertFalse(files.exists)
        XCTAssertThrowsError(try HistoryOpener.open(HistoryDB(), files: files, secret: "s", keychain: true, create: false))
        let db = HistoryDB()
        XCTAssertEqual(try HistoryOpener.open(db, files: files, secret: "pass", keychain: false, create: true).count, 0)
        var s = ChatState()
        var m = Message()
        m.ts = 1
        m.text = "first"
        _ = s.addMessage("+491", m)
        try db.sync(s)
        db.close()
        let again = HistoryDB()
        XCTAssertEqual(try HistoryOpener.open(again, files: files, secret: "pass", keychain: false, create: false)["+491"]?.msgs.first?.text, "first")
    }

    func testBackupIsRemovedAfterItsTime() throws {
        try writeLegacy(state(), passphrase: "p")
        let db = HistoryDB()
        _ = try HistoryOpener.open(db, files: files, secret: "p", keychain: true, create: false)
        db.close()
        HistoryOpener.removeOldBackup(files, now: Date().addingTimeInterval(13 * 86_400))
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.legacyBackup))
        HistoryOpener.removeOldBackup(files, now: Date().addingTimeInterval(15 * 86_400))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.legacyBackup))
    }
}
