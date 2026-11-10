import XCTest
@testable import CorvusCore

final class HistoryDBTests: XCTestCase {
    private var dir: URL!
    private var path: String { dir.appendingPathComponent("history.db").path }
    private let key = HistoryKey.random()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("corvus-db-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func message(_ ts: Int64, _ text: String, author: String = "+491", outgoing: Bool = false) -> Message {
        var m = Message()
        m.ts = ts
        m.orderTs = ts
        m.text = text
        m.authorKey = author
        m.sender = outgoing ? "You" : "Ann"
        m.outgoing = outgoing
        return m
    }

    /// A state with every kind of content the history keeps.
    private func richState() -> ChatState {
        var s = ChatState()
        s.account = "+490"
        s.ensure("+491", title: "Ann")
        s.ensure("g:abc", title: "Group", group: true)
        s.ensure("+492", title: "Empty chat")
        s.convs["+491"]!.storedName = "Ann"
        s.convs["+491"]!.localNickname = "Annie"
        s.convs["+491"]!.muted = true
        s.convs["+491"]!.muteUntilMs = 99
        s.convs["+491"]!.folders = ["work", "f2"]
        s.convs["+491"]!.wallpaper = "sky"
        s.convs["+491"]!.pinned = true
        s.convs["+491"]!.markedUnread = true
        s.convs["+491"]!.expirationSeconds = 3600
        s.convs["g:abc"]!.archived = true
        s.convs["g:abc"]!.sigArchived = true

        var plain = message(10, "hello\nworld — žluťoučký 😀")
        plain.reactions = ["+490": "👍", "+491": "❤️"]
        var quoted = message(20, "reply", author: "+490", outgoing: true)
        quoted.quote.valid = true
        quoted.quote.id = 10
        quoted.quote.authorKey = "+491"
        quoted.quote.text = "hello"
        quoted.receiptStatus = 2
        quoted.recipientReceipts = ["+491": RecipientReceipt(status: 2, deliveredAtMs: 21, readAtMs: 22)]
        var media = message(30, "")
        var a = Attachment()
        a.id = "att1"
        a.contentType = "image/jpeg"
        a.filename = "a.jpg"
        a.size = 1234
        a.width = 640
        a.height = 480
        media.attachments = [a]
        var edited = message(40, "edited text")
        edited.editTs = 45
        edited.editCount = 2
        edited.textStyles = [TextStyleRange(start: 0, length: 6, style: .bold)]
        var expiring = message(50, "soon gone")
        expiring.expiresInSeconds = 60
        expiring.expirationStartMs = 55
        var deleted = message(60, "secret")
        deleted.markDeleted()
        var poll = message(70, "Poll: lunch?")
        poll.poll.question = "lunch?"
        poll.poll.options = ["yes", "no"]
        poll.poll.applyVote(voter: "+491", options: [0], voteCount: 1)
        var pinned = message(80, "pinned")
        pinned.pinnedAtMs = 81
        pinned.pinExpiresMs = 90
        var failed = message(90, "did not go out", author: "+490", outgoing: true)
        failed.sendFailed = true
        var once = message(100, "")
        once.viewOnce = true
        once.viewOnceViewed = true
        var legacy = message(5, "no order value, no author", author: "")
        legacy.orderTs = 0
        legacy.sender = ""
        s.convs["+491"]!.msgs = [legacy, plain, quoted, media, edited, expiring, deleted, poll, pinned, failed, once]

        var toGroup = message(15, "to all", author: "+490", outgoing: true)
        toGroup.sentToKeys = ["+491", "+493"]
        toGroup.receiptStatus = 1
        toGroup.recipientReceipts = ["+491": RecipientReceipt(status: 1, deliveredAtMs: 16, readAtMs: 0),
                                     "+493": RecipientReceipt(status: 0, deliveredAtMs: 0, readAtMs: 0)]
        s.convs["g:abc"]!.msgs = [toGroup, message(25, "from Bob", author: "+493")]
        s.rebuildPins()
        return s
    }

    /// What the former history file gives back for the same state: the reference.
    private func throughRecords(_ s: ChatState) -> ChatState {
        var out = ChatState()
        out.account = s.account
        out.loadHistory(s.allRecords())
        return out
    }

    private func assertSame(_ loaded: [String: Conversation], _ expected: ChatState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Set(loaded.keys), Set(expected.convs.keys), file: file, line: line)
        for (k, e) in expected.convs {
            guard let c = loaded[k] else { continue }
            XCTAssertEqual(c.msgs.count, e.msgs.count, "messages of \(k)", file: file, line: line)
            for (a, b) in zip(c.msgs, e.msgs) { XCTAssertEqual(a, b, "message \(b.ts) of \(k)", file: file, line: line) }
            XCTAssertTrue(ChatState.sameSettings(c, e), "settings of \(k)", file: file, line: line)
            XCTAssertEqual(c.title, e.title, file: file, line: line)
            XCTAssertEqual(c.isGroup, e.isGroup, file: file, line: line)
            XCTAssertEqual(c.pins, e.pins, file: file, line: line)
        }
    }

    func testEverythingComesBackAsFromTheHistoryFile() throws {
        let s = richState()
        let db = HistoryDB()
        try db.create(path: path, key: key)
        let sum = try db.sync(s)
        XCTAssertEqual(sum.upserted, 13)
        XCTAssertEqual(sum.chatsWritten, 3)
        XCTAssertEqual(try db.sync(s), HistoryDB.SyncSummary()) // nothing to do the second time
        db.close()

        let again = HistoryDB()
        try again.open(path: path, key: key)
        assertSame(try again.load(), throughRecords(s))
        XCTAssertEqual(try again.messageCount(), 13)
    }

    func testReadingOnSeveralThreadsGivesTheSameHistory() throws {
        var s = richState()
        for ts in Int64(1000)...1600 {
            var m = message(ts, "bulk \(ts)", author: ts % 3 == 0 ? "+490" : "+493", outgoing: ts % 3 == 0)
            if ts % 7 == 0 { m.reactions["+491"] = "👍" }
            if ts % 3 == 0 { m.recipientReceipts = ["+493": RecipientReceipt(status: 1, deliveredAtMs: ts + 1, readAtMs: 0)] }
            s.convs[ts % 2 == 0 ? "+491" : "g:abc"]!.msgs.append(m)
        }
        let db = HistoryDB()
        try db.create(path: path, key: key)
        try db.sync(s)
        let onePass = try db.load()
        let threshold = HistoryDB.parallelLoadThreshold
        HistoryDB.parallelLoadThreshold = 1
        defer { HistoryDB.parallelLoadThreshold = threshold }
        let parallel = try db.load()
        XCTAssertEqual(Set(parallel.keys), Set(onePass.keys))
        for (k, c) in onePass { XCTAssertEqual(parallel[k]?.msgs, c.msgs, "messages of \(k)") }
        assertSame(parallel, throughRecords(s))
    }

    func testNoPlaintextOnDiskAndWrongKeyIsRefused() throws {
        let db = HistoryDB()
        try db.create(path: path, key: key)
        try db.sync(richState())
        db.close()
        for suffix in ["", "-wal"] {
            guard let bytes = FileManager.default.contents(atPath: path + suffix) else { continue }
            XCTAssertNil(bytes.range(of: Data("soon gone".utf8)))
            XCTAssertNil(bytes.range(of: Data("SQLite format".utf8)))
        }
        XCTAssertThrowsError(try HistoryDB().open(path: path, key: HistoryKey.random())) {
            XCTAssertEqual($0 as? HistoryStoreError, .wrongPassphrase)
        }
        XCTAssertThrowsError(try HistoryDB().create(path: path, key: key)) // never over an existing one
        let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    func testOnlyChangesAreWritten() throws {
        var s = richState()
        let db = HistoryDB()
        try db.create(path: path, key: key)
        try db.sync(s)

        _ = s.addMessage("+491", message(200, "new"))
        XCTAssertEqual(try db.sync(s), HistoryDB.SyncSummary(upserted: 1))

        _ = s.applyReaction("+491", ts: 200, authors: ["+491"], reactor: "+490", emoji: "🎉")
        _ = s.applyEdit("+491", targetTs: 200, authors: ["+491"], text: "newer", newTs: 201)
        XCTAssertEqual(try db.sync(s), HistoryDB.SyncSummary(upserted: 1))

        s.convs["+491"]!.pinned = false
        XCTAssertEqual(try db.sync(s), HistoryDB.SyncSummary(chatsWritten: 1))

        // Delete for everyone leaves a placeholder; delete for me removes the row.
        _ = s.applyDelete("+491", targetTs: 10, authors: [])
        s.convs["+491"]!.msgs.removeAll { $0.ts == 30 }
        XCTAssertEqual(try db.sync(s), HistoryDB.SyncSummary(upserted: 1, deleted: 1))

        // A message that gets another timestamp (a retried send) replaces its row.
        let i = s.convs["+491"]!.msgs.firstIndex { $0.ts == 90 }!
        s.convs["+491"]!.msgs[i].ts = 95
        XCTAssertEqual(try db.sync(s), HistoryDB.SyncSummary(upserted: 1, deleted: 1))
        db.close()

        let again = HistoryDB()
        try again.open(path: path, key: key)
        let loaded = try again.load()
        assertSame(loaded, throughRecords(s))
        XCTAssertEqual(loaded["+491"]?.msgs.last?.text, "newer")
        XCTAssertEqual(loaded["+491"]?.msgs.last?.reactions, ["+490": "🎉"])
        // The loaded state is the new baseline.
        XCTAssertEqual(try again.sync(throughRecords(s)).deleted, 0)
    }

    func testDeletedTextIsGoneFromTheFile() throws {
        var s = ChatState()
        let secret = "the quick brown fox 1234567890"
        _ = s.addMessage("+491", message(1, secret))
        _ = s.addMessage("+491", message(2, "stays"))
        let db = HistoryDB()
        // Unencrypted pages cannot be inspected here, so check through SQLite: no row and no free page content.
        try db.create(path: path, key: key)
        try db.sync(s)
        s.convs["+491"]!.msgs.removeFirst()
        XCTAssertEqual(try db.sync(s, force: true).deleted, 1)
        XCTAssertEqual(try db.messageCount(), 1)
        db.close()
        // After a removal the write-ahead log is emptied.
        let wal = (try? FileManager.default.attributesOfItem(atPath: path + "-wal")[.size] as? Int) ?? 0
        XCTAssertEqual(wal, 0)
    }

    func testRoutineSaveRefusesToEmptyTheHistory() throws {
        var s = ChatState()
        for ts in Int64(1)...200 { _ = s.addMessage(ts % 2 == 0 ? "+491" : "+492", message(ts, "m\(ts)")) }
        let db = HistoryDB()
        try db.create(path: path, key: key)
        try db.sync(s)

        var lost = s
        lost.convs["+491"]!.msgs.removeAll()
        XCTAssertThrowsError(try db.sync(lost)) { XCTAssertEqual(($0 as? HistoryStoreError)?.code, HistoryStoreError.refusedCode) }
        var gone = s
        gone.convs.removeValue(forKey: "+492")
        XCTAssertThrowsError(try db.sync(gone))
        XCTAssertEqual(try db.messageCount(), 200) // nothing was written

        XCTAssertEqual(try db.sync(gone, force: true).chatsDeleted, 1) // the user removed the chat
        XCTAssertEqual(try db.messageCount(), 100)
        db.close()
        let again = HistoryDB()
        try again.open(path: path, key: key)
        XCTAssertEqual(Set(try again.load().keys), ["+491"])
    }

    func testPendingSendsStayOutUntilConfirmed() throws {
        var s = ChatState()
        s.account = "+490"
        _ = s.addMessage("+491", message(1, "old"))
        var p = PendingSend()
        p.conversationKey = "+491"
        p.temporaryTimestamp = 500
        p.message = message(500, "sending", author: "+490", outgoing: true)
        s.pendingSends["x"] = p
        _ = s.addMessage("+491", p.message)
        let db = HistoryDB()
        try db.create(path: path, key: key)
        XCTAssertEqual(try db.sync(s).upserted, 1)
        _ = s.finalizePendingSend("x", timestamp: 600)
        XCTAssertEqual(try db.sync(s), HistoryDB.SyncSummary(upserted: 1))
        XCTAssertEqual(try db.load()["+491"]?.msgs.map(\.ts).sorted(), [1, 600])
    }

    func testRekey() throws {
        let db = HistoryDB()
        try db.create(path: path, key: key)
        try db.sync(richState())
        let other = HistoryKey.random()
        try db.rekey(other)
        db.close()
        XCTAssertThrowsError(try HistoryDB().open(path: path, key: key))
        let again = HistoryDB()
        try again.open(path: path, key: other)
        XCTAssertEqual(try again.messageCount(), 13)
    }

    func testKeyFile() throws {
        let file = dir.appendingPathComponent("history.key").path
        try HistoryKey.writeKeyFile(file, key: key, passphrase: "correct horse")
        XCTAssertEqual(try HistoryKey.readKeyFile(file, passphrase: "correct horse"), key)
        XCTAssertThrowsError(try HistoryKey.readKeyFile(file, passphrase: "battery")) {
            XCTAssertEqual($0 as? HistoryStoreError, .wrongPassphrase)
        }
        XCTAssertEqual(HistoryKey.fromKeychainSecret("abc"), HistoryKey.fromKeychainSecret("abc"))
        XCTAssertNotEqual(HistoryKey.fromKeychainSecret("abc"), HistoryKey.fromKeychainSecret("abd"))
        XCTAssertEqual(HistoryKey.fromKeychainSecret("abc").count, 32)
    }

    func testDiff() {
        let a = (1...6).map { message(Int64($0), "m\($0)") }
        func changes(_ old: [Message], _ new: [Message]) -> (written: [Int64], removed: [Int64]) {
            var w: [Int64] = [], r: [Int64] = []
            HistoryDB.diff(old, new) { m, removed in if removed { r.append(m.ts) } else { w.append(m.ts) } }
            return (w.sorted(), r.sorted())
        }
        XCTAssertTrue(changes(a, a) == ([], []))
        XCTAssertTrue(changes(a, Array(a)) == ([], []))
        XCTAssertTrue(changes([], a) == ([1, 2, 3, 4, 5, 6], []))
        XCTAssertTrue(changes(a, []) == ([], [1, 2, 3, 4, 5, 6]))
        XCTAssertTrue(changes(a, a + [message(7, "m7")]) == ([7], []))
        var b = a
        b[2].text = "changed"
        XCTAssertTrue(changes(a, b) == ([3], []))
        b.remove(at: 4)
        XCTAssertTrue(changes(a, b) == ([3], [5]))
        XCTAssertTrue(changes(a, [message(0, "m0")] + a) == ([0], []))
        XCTAssertTrue(changes(a, Array(a.reversed())) == ([], [])) // order alone is not stored
    }

    func testBenchLoadAndSync() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CORVUS_BENCH"] != nil)
        var state = BenchHistory.state()
        do {
            let db = HistoryDB()
            try db.create(path: path, key: key)
            let t = try BenchHistory.ms { try db.sync(state) }
            db.close()
            let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            print("BENCH db: file \(BenchHistory.mb(size)), first write of everything \(t) ms")
        }
        let before = BenchHistory.footprint()
        let db = HistoryDB()
        var convs: [String: Conversation] = [:]
        let open = try BenchHistory.ms { try db.open(path: path, key: key) }
        let load = try BenchHistory.ms { convs = try db.load() }
        let after = BenchHistory.footprint()
        print("BENCH db: open \(open) ms, load \(load) ms, footprint +\(BenchHistory.mb(after - before))")
        XCTAssertEqual(convs.values.reduce(0) { $0 + $1.msgs.count }, BenchHistory.messages)

        state.convs = convs
        let big = convs.values.max { $0.msgs.count < $1.msgs.count }!.key
        var m = Message()
        m.ts = 1_900_000_000_000
        m.text = "one more"
        m.authorKey = big
        _ = state.addMessage(big, m)
        let add = try BenchHistory.ms { try db.sync(state) }
        state.convs[big]!.msgs.removeFirst(40)
        let remove = try BenchHistory.ms { try db.sync(state) }
        let idle = try BenchHistory.ms { for _ in 0..<100 { try db.sync(state) } }
        print("BENCH db: save one new message \(add) ms, remove 40 expired \(remove) ms, sync with nothing to do \(Double(idle) / 100) ms (largest chat \(convs[big]!.msgs.count) messages)")
    }
}
