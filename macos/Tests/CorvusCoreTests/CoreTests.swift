import XCTest
@testable import CorvusCore

final class EnvelopeTests: XCTestCase {
    func testIncomingMessageWithQuoteAndAttachment() {
        let env: JSON = [
            "sourceNumber": "+4915112345", "sourceUuid": "u-1", "sourceName": "Alice", "timestamp": 1000,
            "dataMessage": [
                "timestamp": 1234, "message": "hi",
                "attachments": [["id": "att1", "contentType": "image/png", "filename": "a.png", "size": 42, "width": 3, "height": 4]],
                "quote": ["id": 999, "authorUuid": "u-2", "text": "orig", "attachments": [["contentType": "image/jpeg"]]],
            ] as JSON,
        ]
        let pe = parseEnvelope(env)
        XCTAssertEqual(pe.kind, .message)
        XCTAssertEqual(pe.src, "+4915112345")
        XCTAssertEqual(pe.srcName, "Alice")
        XCTAssertEqual(pe.msg.ts, 1234)
        XCTAssertEqual(pe.msg.text, "hi")
        XCTAssertEqual(pe.msg.attachments.first?.id, "att1")
        XCTAssertEqual(pe.msg.attachments.first?.size, 42)
        XCTAssertTrue(pe.msg.quote.valid)
        XCTAssertEqual(pe.msg.quote.authorKey, "u-2")
        XCTAssertEqual(pe.msg.quote.attachmentNote, "image/jpeg")
    }

    func testMentions() {
        let pe = parseEnvelope(["sourceNumber": "+49111", "dataMessage": [
            "timestamp": 1, "message": "\u{FFFC} hi \u{FFFC}",
            "mentions": [["name": "+49222", "number": "+49222", "uuid": "u-2", "start": 0, "length": 1],
                         ["name": "Bob", "number": "", "uuid": "u-3", "start": 5, "length": 1]],
        ] as JSON])
        XCTAssertEqual(pe.mentions, [Mention(start: 0, length: 1, number: "+49222", uuid: "u-2", name: "+49222"),
                                     Mention(start: 5, length: 1, uuid: "u-3", name: "Bob")])
        let names = ["+49222": "Alice", "u-3": "Bob"]
        XCTAssertEqual(applyMentions(pe.msg.text, pe.mentions) { names[$0.number.isEmpty ? $0.uuid : $0.number]! }, "@Alice hi @Bob")
        // Emoji before the placeholder: offsets are UTF-16 units.
        XCTAssertEqual(applyMentions("😀 \u{FFFC}", [Mention(start: 3, length: 1)]) { _ in "X" }, "😀 @X")
        // Out of range mentions are ignored.
        XCTAssertEqual(applyMentions("hi", [Mention(start: 5, length: 1)]) { _ in "X" }, "hi")
    }

    func testReactionEditSyncAndReceipts() {
        let reaction = parseEnvelope(["sourceUuid": "u-1", "dataMessage": [
            "reaction": ["emoji": "👍", "targetAuthorNumber": "+49111", "targetSentTimestamp": 77, "isRemove": false],
            "groupInfo": ["groupId": "G1"],
        ] as JSON])
        XCTAssertEqual(reaction.kind, .reaction)
        XCTAssertEqual(reaction.src, "u-1")
        XCTAssertEqual(reaction.groupId, "G1")
        XCTAssertEqual(reaction.targetTs, 77)

        let edit = parseEnvelope(["source": "+49222", "editMessage": [
            "targetSentTimestamp": 5, "dataMessage": ["timestamp": 9, "message": "fixed"],
        ] as JSON])
        XCTAssertEqual(edit.kind, .edit)
        XCTAssertEqual(edit.targetTs, 5)
        XCTAssertEqual(edit.msg.ts, 9)

        let sync = parseEnvelope(["sourceNumber": "+49me", "syncMessage": ["sentMessage": [
            "destinationNumber": "+49333", "timestamp": 11, "message": "from phone", "expiresInSeconds": 30,
        ] as JSON]])
        XCTAssertEqual(sync.kind, .message)
        XCTAssertTrue(sync.outgoing)
        XCTAssertTrue(sync.msg.outgoing)
        XCTAssertEqual(sync.destination, "+49333")
        XCTAssertEqual(sync.msg.expiresInSeconds, 30)

        let delete = parseEnvelope(["sourceUuid": "u-1", "dataMessage": [
            "timestamp": 20, "remoteDelete": ["timestamp": 15], "groupInfo": ["groupId": "G1"],
        ] as JSON])
        XCTAssertEqual(delete.kind, .remoteDelete)
        XCTAssertEqual(delete.src, "u-1")
        XCTAssertEqual(delete.groupId, "G1")
        XCTAssertEqual(delete.targetTs, 15)

        let syncDelete = parseEnvelope(["sourceNumber": "+49me", "syncMessage": ["sentMessage": [
            "destinationNumber": "+49333", "timestamp": 21, "remoteDelete": ["timestamp": 11],
        ] as JSON]])
        XCTAssertEqual(syncDelete.kind, .remoteDelete)
        XCTAssertTrue(syncDelete.outgoing)
        XCTAssertEqual(syncDelete.destination, "+49333")
        XCTAssertEqual(syncDelete.targetTs, 11)

        XCTAssertEqual(parseEnvelope(["sourceNumber": "+1", "receiptMessage": ["isRead": true]]).kind, .none)
        XCTAssertEqual(parseEnvelope(["sourceNumber": "+1", "dataMessage": ["timestamp": 1]]).kind, .none)
        XCTAssertEqual(parseEnvelope(["sourceNumber": "+1", "dataMessage": ["isExpirationUpdate": true, "expiresInSeconds": 60]]).kind,
                       .expirationUpdate)
    }
}

final class SignalCliHelperTests: XCTestCase {
    func testParseAccounts() {
        XCTAssertEqual(SignalCli.parseAccounts(#"[{"number":"+491234567"},"+15550001"]"#), ["+491234567", "+15550001"])
        XCTAssertEqual(SignalCli.parseAccounts("WARN something\nNumber: +4917000000\nNumber: +4917000000"), ["+4917000000"])
        XCTAssertEqual(SignalCli.parseAccounts("[]"), [])
    }

    func testMaskNumbers() {
        XCTAssertEqual(SignalCli.maskNumbers("call +4915112345678 now"), "call +49…78 now")
    }

    func testDescribe() {
        var r = CliResult()
        r.exitCode = 3
        r.err = "boom"
        XCTAssertEqual(r.describe(), "signal-cli exited with code 3.\n\nboom")
        r.timedOut = true
        XCTAssertEqual(r.describe(), "signal-cli did not answer in time.")
    }
}

final class ModelTests: XCTestCase {
    func testEditRules() {
        var m = Message()
        m.outgoing = true
        m.text = "x"
        m.ts = 1_000
        XCTAssertTrue(m.canEdit(nowMs: 1_000 + Message.editWindowMs))
        XCTAssertFalse(m.canEdit(nowMs: 1_001 + Message.editWindowMs))
        m.editCount = Message.maxEdits
        XCTAssertFalse(m.canEdit(nowMs: 1_000))
    }

    func testAttachmentKinds() {
        var a = Attachment()
        a.filename = "voice.OPUS"
        XCTAssertTrue(a.isAudio)
        a.filename = "clip.mov"
        XCTAssertTrue(a.isVideo)
        a.contentType = "image/gif"
        XCTAssertTrue(a.isGif)
        XCTAssertTrue(a.isImage)
    }
}

final class ChatStateTests: XCTestCase {
    func makeState() -> ChatState {
        var s = ChatState()
        s.account = "+49me"
        s.alias["u-alice"] = "+49alice"
        return s
    }

    func testAddDeduplicatesAndUnarchives() {
        var s = makeState()
        var m = Message()
        m.ts = 10
        m.text = "a"
        m.authorKey = "+49alice"
        s.ensure("+49alice")
        s.convs["+49alice"]!.archived = true
        let first = s.addMessage("+49alice", m)
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.records.count, 2) // message + archive
        XCTAssertFalse(s.convs["+49alice"]!.archived)
        XCTAssertNil(s.addMessage("+49alice", m))
    }

    func testIncorrectSenderClockDoesNotInsertNewMessageIntoPast() {
        var s = makeState()
        s.ensure("+49alice")

        // Simulate a legacy history entry whose sender clock was far ahead of ours.
        var old = Message()
        old.ts = nowMs() + 60 * 60 * 1000
        old.text = "Earlier message with a bad clock"
        old.authorKey = "+49alice"
        s.convs["+49alice"]!.msgs.append(old)

        // The next message has a sender timestamp far in the past, but arrived now.
        var incoming = Message()
        incoming.ts = 1_000
        incoming.text = "New message"
        incoming.authorKey = "+49alice"
        XCTAssertNotNil(s.addMessage("+49alice", incoming))

        let conversation = s.convs["+49alice"]!
        XCTAssertEqual(conversation.msgs.last?.text, "New message")
        XCTAssertGreaterThan(conversation.msgs.last!.sortTs, old.sortTs)

        // The independent ordering value must survive encrypted-history compaction/reload.
        var reloaded = makeState()
        reloaded.loadHistory(s.allRecords())
        XCTAssertEqual(reloaded.convs["+49alice"]!.msgs.last?.text, "New message")
        XCTAssertEqual(reloaded.convs["+49alice"]!.msgs.last?.orderTs, conversation.msgs.last?.orderTs)
    }

    func testReactionEditAndReload() {
        var s = makeState()
        var m = Message()
        m.ts = 10
        m.text = "a"
        m.authorKey = "+49alice"
        var records = s.addMessage("+49alice", m)!.records
        // reaction refers to the author by uuid -> resolved through the alias
        records.append(s.applyReaction("+49alice", ts: 10, authors: ["u-alice"], reactor: "+49me", emoji: "❤️")!)
        records.append(s.applyEdit("+49alice", targetTs: 10, authors: ["+49alice"], text: "b", newTs: 20)!)
        XCTAssertNil(s.applyEdit("+49alice", targetTs: 10, authors: ["+49alice"], text: "old", newTs: 15))
        // the edited message is also found by its latest timestamp
        XCTAssertNotNil(s.findMessage(s.convs["+49alice"]!, ts: 20, authors: []))

        var reloaded = makeState()
        reloaded.loadHistory(records)
        let msg = reloaded.convs["+49alice"]!.msgs[0]
        XCTAssertEqual(msg.text, "b")
        XCTAssertEqual(msg.editCount, 1)
        XCTAssertEqual(msg.reactions["+49me"], "❤️")

        // compaction output reproduces the same state
        var compacted = makeState()
        compacted.loadHistory(reloaded.allRecords())
        XCTAssertEqual(compacted.convs["+49alice"]!.msgs, reloaded.convs["+49alice"]!.msgs)
    }

    func testDeleteLeavesPlaceholder() {
        var s = makeState()
        var m = Message()
        m.ts = 10
        m.text = "secret"
        m.authorKey = "+49alice"
        m.quote.valid = true
        m.attachments = [Attachment()]
        var records = s.addMessage("+49alice", m)!.records
        records.append(s.applyReaction("+49alice", ts: 10, authors: ["+49alice"], reactor: "+49me", emoji: "❤️")!)
        // only the author can delete for everyone
        XCTAssertNil(s.applyDelete("+49alice", targetTs: 10, authors: ["+49bob"]))
        records.append(s.applyDelete("+49alice", targetTs: 10, authors: ["u-alice"])!)
        XCTAssertNil(s.applyDelete("+49alice", targetTs: 10, authors: ["+49alice"])) // redelivery

        let placeholder = s.convs["+49alice"]!.msgs[0]
        XCTAssertTrue(placeholder.deleted)
        XCTAssertEqual(placeholder.text, "")
        XCTAssertTrue(placeholder.attachments.isEmpty && placeholder.reactions.isEmpty && !placeholder.quote.valid)
        // a deleted message takes no more reactions or edits
        XCTAssertNil(s.applyReaction("+49alice", ts: 10, authors: [], reactor: "+49me", emoji: "👍"))
        XCTAssertNil(s.applyEdit("+49alice", targetTs: 10, authors: ["+49alice"], text: "back", newTs: 20))

        // appended history and compacted history both reload as the placeholder, without the content
        var reloaded = makeState()
        reloaded.loadHistory(records)
        XCTAssertEqual(reloaded.convs["+49alice"]!.msgs, [placeholder])
        let compactedRecords = s.allRecords()
        XCTAssertEqual(jsonString(compactedRecords.first { jsonString($0["t"]) == "m" }?["x"]), "")
        var compacted = makeState()
        compacted.loadHistory(compactedRecords)
        XCTAssertEqual(compacted.convs["+49alice"]!.msgs, [placeholder])
    }

    func testExpiry() {
        var s = makeState()
        var m = Message()
        m.ts = 10
        m.text = "gone"
        m.expiresInSeconds = 30
        _ = s.addMessage("+49bob", m)
        XCTAssertEqual(s.startIncomingExpirationTimers("+49bob", now: 1_000).count, 1)
        XCTAssertFalse(s.hasExpiredMessages(now: 1_000 + 29_999))
        XCTAssertFalse(s.expireMessages(now: 1_000 + 29_999))
        XCTAssertTrue(s.hasExpiredMessages(now: 1_000 + 30_000))
        XCTAssertTrue(s.expireMessages(now: 1_000 + 30_000))
        XCTAssertFalse(s.hasExpiredMessages(now: 1_000 + 30_000))
        XCTAssertTrue(s.convs["+49bob"]!.msgs.isEmpty)
    }

    func testPendingSendConfirmedByEcho() {
        var s = makeState()
        s.ensure("+49bob")
        var preview = Message()
        preview.ts = 100
        preview.text = "hello"
        preview.outgoing = true
        preview.authorKey = "+49me"
        s.convs["+49bob"]!.insertSorted(preview)
        var p = PendingSend()
        p.conversationKey = "+49bob"
        p.temporaryTimestamp = 100
        p.message = preview
        s.pendingSends["id1"] = p
        XCTAssertEqual(s.allRecords().filter { jsonString($0["t"]) == "m" }.count, 0) // previews are not persisted

        var echo = preview
        echo.ts = 150
        XCTAssertEqual(s.pendingSendMatching(echo: echo, key: "+49bob"), "id1")
        let recs = s.finalizePendingSend("id1", timestamp: 150, echo: echo)
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(s.convs["+49bob"]!.msgs.map(\.ts), [150])
        XCTAssertTrue(s.pendingSends["id1"]!.echoReceived)
        // A second identical echo belongs to an already confirmed message.
        XCTAssertNil(s.pendingSendMatching(echo: echo, key: "+49bob"))
    }
}

final class HistoryStoreTests: XCTestCase {
    func testRoundTripThroughRustStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("history.corvus").path

        var m = Message()
        m.ts = 1_700_000_000_000
        m.text = "secret text"
        m.authorKey = "+49alice"
        m.quote.valid = true
        m.quote.id = 5
        var a = Attachment()
        a.id = "x"
        a.contentType = "image/png"
        a.thumb = Data([1, 2, 3])
        m.attachments = [a]
        m.expiresInSeconds = 60
        m.expirationStartMs = 2
        var second = m
        second.ts += 10
        second.text = "deleted later"

        let records: [JSON] = [
            Records.message("+49alice", m),
            Records.name("+49alice", "Alice"),
            Records.nickname("+49alice", "Ali"),
            Records.archive("+49alice", archived: true, sigArchived: false),
            Records.mute("+49alice", true),
            Records.expiration("+49alice", 60),
            Records.reaction("+49alice", ts: m.ts, author: "+49alice", by: "+49me", emoji: "👍"),
            Records.edit("+49alice", { var e = m; e.text = "edited"; e.editTs = m.ts + 1; e.editCount = 1; return e }()),
            Records.attachmentsUpdate("+49alice", m),
            Records.expirationUpdate("+49alice", m),
            Records.message("+49alice", second),
            Records.deletion("+49alice", second),
            Records.message("+49alice", { var d = second; d.ts += 5; d.markDeleted(); return d }()),
        ]

        let store = HistoryStore()
        XCTAssertFalse(HistoryStore.exists(path))
        try store.create(path: path, passphrase: "pw")
        for r in records { try store.append(r) } // the Rust Record enum must accept every shape
        store.close()

        XCTAssertThrowsError(try HistoryStore().open(path: path, passphrase: "wrong")) { e in
            XCTAssertEqual(e as? HistoryStoreError, .wrongPassphrase)
        }
        let reopened = HistoryStore()
        let loaded = try reopened.open(path: path, passphrase: "pw")
        XCTAssertEqual(loaded.count, records.count)

        var s = ChatState()
        s.loadHistory(loaded)
        let c = s.convs["+49alice"]!
        XCTAssertEqual(c.title, "Ali")
        XCTAssertTrue(c.archived && c.muted)
        XCTAssertEqual(c.msgs.first?.text, "edited")
        XCTAssertEqual(c.msgs.first?.attachments.first?.thumb, Data([1, 2, 3]))
        XCTAssertEqual(c.msgs.first?.reactions["+49me"], "👍")
        XCTAssertEqual(c.msgs.count, 3)
        XCTAssertTrue(c.msgs[1].deleted && c.msgs[2].deleted)
        XCTAssertEqual(c.msgs[1].text, "")

        try reopened.rewrite(s.allRecords())
        try reopened.changePassphrase(old: "pw", new: "pw2")
        reopened.close()
        XCTAssertNoThrow(try HistoryStore().open(path: path, passphrase: "pw2"))

        // The file never contains the plaintext.
        let raw = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertNil(raw.range(of: Data("secret text".utf8)))
    }
}

@MainActor
final class SignalCliProcessTests: XCTestCase {
    /// Runs the Python mock of the Qt test-suite as signal-cli. The repository copy is not
    /// executable (CMake copies it with the right mode), so the test does the same.
    func mockPath() throws -> String {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("../../../tests/mock-signal-cli.py").standardized
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("mock-signal-cli-\(UUID().uuidString).py")
        try FileManager.default.copyItem(at: source, to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        return target.path
    }

    func testOneShotAndJsonRpcAgainstMock() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"), "python3 missing")
        let cli = SignalCli()
        cli.executable = try mockPath()
        defer { try? FileManager.default.removeItem(atPath: cli.executable) }
        let (vr, version) = await cli.queryVersion()
        XCTAssertTrue(vr.ok, vr.describe())
        XCTAssertEqual(version, "signal-cli 0.14.9")
        let (ar, accounts) = await cli.queryAccounts()
        XCTAssertTrue(ar.ok)
        XCTAssertEqual(accounts, ["+491234567"])

        cli.start(account: "+491234567")
        let contacts = try await cli.call("listContacts")
        XCTAssertNotNil(contacts as? [Any])
        do {
            _ = try await cli.call("noSuchMethodHopefully")
        } catch {
            // either an RPC error or a result, but never a hang
        }
        cli.stop()
        XCTAssertFalse(cli.isRunning)
    }
}

final class AttachmentPolicyTests: XCTestCase {
    private func policy(_ name: String, _ mime: String = "application/octet-stream", media: Bool = false) -> AttachmentPolicy {
        AttachmentPolicy.classify(filename: name, contentType: mime, isMedia: media)
    }

    func testRunnableFilesAreRisky() {
        for name in ["x.terminal", "run.sh", "a.command", "Tool.app", "x.py", "s.applescript", "l.fileloc", "noext",
                     "X.TERMINAL", "x.terminal ", "x.terminal.", "dir/x.zsh"] {
            XCTAssertEqual(policy(name), .risky, name)
        }
    }

    func testSenderContentTypeCannotHideRiskyFiles() {
        XCTAssertEqual(policy("x.terminal", "image/png", media: true), .risky)
        XCTAssertEqual(policy("x.sh", "video/mp4", media: true), .risky)
        XCTAssertEqual(policy("a.pdf", "application/x-sh"), .risky)
        XCTAssertEqual(policy("a.pdf", "text/x-shellscript; charset=utf-8"), .risky)
    }

    func testOtherFilesAskAndMediaStaysInApp() {
        XCTAssertEqual(policy("a.pdf", "application/pdf"), .ask)
        XCTAssertEqual(policy("notes.txt", "text/plain"), .ask)
        XCTAssertEqual(policy("archive.zip", "application/zip"), .ask)
        XCTAssertEqual(policy("photo.jpg", "image/jpeg", media: true), .inApp)
        XCTAssertEqual(policy("", "audio/aac", media: true), .inApp) // voice notes have no file name
    }

    func testMediaSuffixNeverTakesTheSendersExtension() {
        XCTAssertEqual(AttachmentPolicy.mediaSuffix(filename: "clip.mov", contentType: "video/quicktime", fallback: "mp4"), "mov")
        XCTAssertEqual(AttachmentPolicy.mediaSuffix(filename: "x.terminal", contentType: "video/mp4", fallback: "mp4"), "mp4")
        XCTAssertEqual(AttachmentPolicy.mediaSuffix(filename: "x.terminal", contentType: "text/plain", fallback: "m4a"), "m4a")
    }
}

final class DesktopParityTests: XCTestCase {
    func testStickerViewOnceAndStoryContext() {
        let st = parseEnvelope(["sourceNumber": "+49111", "dataMessage": [
            "timestamp": 5, "sticker": ["packId": "abcd", "stickerId": 7],
        ] as JSON])
        XCTAssertEqual(st.kind, .message)
        XCTAssertTrue(st.msg.attachments[0].isSticker)
        XCTAssertEqual(st.msg.attachments[0].stickerPackId, "abcd")
        XCTAssertEqual(st.msg.attachments[0].stickerId, 7)
        XCTAssertEqual(st.msg.attachments[0].filename, "signal-sticker:abcd:7.webp") // same as the Qt app

        let vo = parseEnvelope(["sourceNumber": "+49111", "dataMessage": [
            "timestamp": 6, "viewOnce": true, "attachments": [["id": "a1", "contentType": "image/jpeg"]],
        ] as JSON])
        XCTAssertTrue(vo.msg.viewOnce)

        let reply = parseEnvelope(["sourceNumber": "+49111", "dataMessage": [
            "timestamp": 7, "message": "nice",
            "storyContext": ["authorNumber": "+49222", "sentTimestamp": 99],
        ] as JSON])
        XCTAssertEqual(reply.kind, .message)
        XCTAssertEqual(reply.msg.quote.id, 99)
        XCTAssertEqual(reply.msg.quote.attachmentNote, "story")

        let react = parseEnvelope(["sourceNumber": "+49111", "dataMessage": [
            "timestamp": 8, "reaction": ["emoji": "❤️", "targetSentTimestamp": 99, "isRemove": false],
            "storyContext": ["authorNumber": "+49222", "sentTimestamp": 99],
        ] as JSON])
        XCTAssertEqual(react.kind, .message)
        XCTAssertTrue(react.isStoryReaction)
        XCTAssertEqual(react.msg.text, "❤️")
    }

    func testStories() {
        let pe = parseEnvelope(["sourceNumber": "+49111", "sourceName": "Alice", "timestamp": 1000, "storyMessage": [
            "allowsReplies": false, "fileAttachment": ["id": "s1", "contentType": "image/jpeg"],
        ] as JSON])
        XCTAssertEqual(pe.kind, .story)
        XCTAssertEqual(pe.story.ts, 1000)
        XCTAssertFalse(pe.story.allowsReplies)
        XCTAssertEqual(pe.story.attachment?.id, "s1")
        XCTAssertEqual(pe.story.authorName, "Alice")

        let text = parseEnvelope(["sourceNumber": "+49111", "timestamp": 2000, "storyMessage": [
            "allowsReplies": true, "groupId": "G1",
            "textAttachment": ["text": "hello", "textForegroundColor": "#FFFFFFFF", "backgroundColor": "#FF112233"],
        ] as JSON])
        XCTAssertEqual(text.kind, .story)
        XCTAssertEqual(text.story.text, "hello")
        XCTAssertEqual(text.story.groupId, "G1")
        XCTAssertTrue(text.story.isExpired(now: 2000 + 25 * 3600 * 1000))
        XCTAssertFalse(text.story.isExpired(now: 2000 + 23 * 3600 * 1000))

        let own = parseEnvelope(["sourceNumber": "+49000", "timestamp": 3000, "syncMessage": [
            "sentStoryMessage": ["allowsReplies": true, "fileAttachment": ["id": "s2", "contentType": "video/mp4"]],
        ] as JSON])
        XCTAssertEqual(own.kind, .story)
        XCTAssertTrue(own.story.outgoing)
    }

    func testPollsEndToEnd() {
        let create = parseEnvelope(["sourceNumber": "+49111", "dataMessage": [
            "timestamp": 10, "pollCreate": ["question": "Lunch?", "allowMultiple": false, "options": ["Pizza", "Sushi"]],
        ] as JSON])
        XCTAssertEqual(create.kind, .message)
        XCTAssertTrue(create.msg.isPoll)
        XCTAssertEqual(create.msg.text, "📊 Lunch?") // fallback text for clients without polls
        XCTAssertFalse(create.msg.poll.allowMultiple)

        var s = ChatState()
        s.account = "+49000"
        var m = create.msg
        m.authorKey = "+49111"
        _ = s.addMessage("+49111", m)

        let vote = parseEnvelope(["sourceNumber": "+49222", "dataMessage": [
            "timestamp": 11, "groupInfo": ["groupId": ""],
            "pollVote": ["authorNumber": "+49111", "targetSentTimestamp": 10, "optionIndexes": [1, 0], "voteCount": 2],
        ] as JSON])
        XCTAssertEqual(vote.kind, .pollVote)
        XCTAssertEqual(vote.pollOptions, [1, 0])
        XCTAssertNotNil(s.applyPollVote("+49111", targetTs: 10, authors: ["+49111"], voter: "+49222", options: vote.pollOptions, voteCount: 2))
        // Single choice: only the first option counts.
        XCTAssertEqual(s.convs["+49111"]!.msgs[0].poll.votes["+49222"], [1])
        // An older vote does not replace a newer one.
        XCTAssertNil(s.applyPollVote("+49111", targetTs: 10, authors: ["+49111"], voter: "+49222", options: [0], voteCount: 1))
        let rec = s.applyPollVote("+49111", targetTs: 10, authors: ["+49111"], voter: "+49000", options: [0], voteCount: 1)!

        let term = parseEnvelope(["sourceNumber": "+49111", "dataMessage": ["timestamp": 12, "pollTerminate": ["targetSentTimestamp": 10]] as JSON])
        XCTAssertEqual(term.kind, .pollTerminate)
        // Only the author can end a poll.
        XCTAssertNil(s.applyPollTerminate("+49111", targetTs: 10, authors: ["+49222"]))
        let endRec = s.applyPollTerminate("+49111", targetTs: 10, authors: ["+49111"])!
        XCTAssertNil(s.applyPollVote("+49111", targetTs: 10, authors: ["+49111"], voter: "+49333", options: [0], voteCount: 1))

        // History: message + updates reproduce the state.
        var r = ChatState()
        r.account = "+49000"
        r.loadHistory([Records.message("+49111", m), rec, endRec])
        let p = r.convs["+49111"]!.msgs[0].poll
        XCTAssertEqual(p.votes["+49000"], [0])
        XCTAssertTrue(p.ended)
        // Compaction keeps everything.
        var r2 = ChatState()
        r2.loadHistory(s.allRecords())
        XCTAssertEqual(r2.convs["+49111"]!.msgs[0].poll, s.convs["+49111"]!.msgs[0].poll)
    }

    func testViewOnceIsNeverKeptOnceOpened() {
        var m = Message()
        m.ts = 20
        m.authorKey = "+49111"
        m.viewOnce = true
        var a = Attachment()
        a.id = "secret"
        a.contentType = "image/jpeg"
        a.thumb = Data([1, 2, 3])
        m.attachments = [a]
        // Unopened incoming: only the reference, never a preview.
        let rec = Records.message("+49111", m)
        let at = jsonArray(jsonObject(rec["d"])["at"])
        XCTAssertEqual(jsonString(jsonObject(at.first)["id"]), "secret")
        XCTAssertNil(jsonObject(at.first)["th"])

        var s = ChatState()
        s.loadHistory([rec])
        let upd = s.markViewOnceViewed("+49111", ts: 20, authors: ["+49111"])!
        XCTAssertTrue(s.convs["+49111"]!.msgs[0].attachments.isEmpty)
        XCTAssertNil(jsonObject(s.allRecords().first { jsonString($0["t"]) == "m" }?["d"])["at"])

        var r = ChatState()
        r.loadHistory([rec, upd])
        XCTAssertTrue(r.convs["+49111"]!.msgs[0].viewOnceConsumed)
        XCTAssertTrue(r.convs["+49111"]!.msgs[0].attachments.isEmpty)

        // Sent View Once media is never stored.
        var out = m
        out.outgoing = true
        XCTAssertNil(jsonObject(Records.message("+49111", out)["d"])["at"])
    }
}

// MARK: - Groups, blocking and message requests

final class GroupInfoTests: XCTestCase {
    private let me = "+49111000"

    private func detailed() -> JSON {
        [
            "id": "R1JPVVA=", "name": "Team", "description": "Plans", "isMember": true, "isBlocked": false,
            "messageExpirationTime": 3600,
            "members": [["number": "+49111000", "uuid": "u-me", "isAdmin": true],
                        ["number": "+49222000", "uuid": "u-bob", "isAdmin": false],
                        ["number": NSNull(), "uuid": "u-carol", "isAdmin": false]],
            "pendingMembers": [["number": "+49333000", "uuid": "u-dave"]],
            "requestingMembers": [["number": "+49444000", "uuid": "u-erin"]],
            "banned": [["number": "+49555000", "uuid": "u-mallory"]],
            "permissionAddMember": "ONLY_ADMINS", "permissionEditDetails": "EVERY_MEMBER",
            "permissionSendMessage": "every-member",
            "groupInviteLink": "https://signal.group/#abc",
        ]
    }

    func testParsesDetailedGroup() {
        let g = GroupInfo(json: detailed())
        XCTAssertEqual(g.key, "g:R1JPVVA=")
        XCTAssertEqual(g.name, "Team")
        XCTAssertEqual(g.description, "Plans")
        XCTAssertEqual(g.expiration, 3600)
        XCTAssertEqual(g.members.map(\.id), ["+49111000", "+49222000", "u-carol"])
        XCTAssertEqual(g.members.map(\.isAdmin), [true, false, false])
        XCTAssertEqual(g.pending.map(\.id), ["+49333000"])
        XCTAssertEqual(g.requesting.map(\.id), ["+49444000"])
        XCTAssertEqual(g.banned.map(\.id), ["+49555000"])
        XCTAssertEqual(g.permAddMember, .onlyAdmins)
        XCTAssertEqual(g.permEditDetails, .everyMember)
        XCTAssertTrue(g.inviteLinkEnabled)
        XCTAssertEqual(g.inviteLink, "https://signal.group/#abc")
        XCTAssertEqual(g.adminCount, 1)
    }

    func testLegacyStringMembersAndSeparateAdminList() {
        let g = GroupInfo(json: ["id": "x", "name": "Old", "members": ["+49111000", "u-bob"], "admins": ["u-bob"],
                                 "groupInviteLink": NSNull()])
        XCTAssertEqual(g.members.map(\.id), ["+49111000", "u-bob"])
        XCTAssertEqual(g.members.map(\.isAdmin), [false, true])
        XCTAssertFalse(g.inviteLinkEnabled)
        XCTAssertTrue(g.isMember) // no isMember field: a member
    }

    func testParseListDropsEntriesWithoutId() {
        XCTAssertEqual(GroupInfo.parseList([["id": "a", "name": "A"], ["name": "no id"]] as [JSON]).map(\.id), ["a"])
        XCTAssertTrue(GroupInfo.parseList(nil).isEmpty)
    }

    func testPermissions() {
        let g = GroupInfo(json: detailed())
        XCTAssertTrue(g.canAddMembers(me))              // admin
        XCTAssertFalse(g.canAddMembers("+49222000"))    // only admins may add
        XCTAssertTrue(g.canEditDetails("+49222000"))    // everybody may edit
        XCTAssertFalse(g.canEditDetails("+49999000"))   // not a member
        XCTAssertTrue(g.canAdminister(me))
        XCTAssertFalse(g.canAdminister("u-bob"))
    }

    func testOnlyAdminNeedsSuccessorToLeave() {
        let g = GroupInfo(json: detailed())
        XCTAssertTrue(g.needsSuccessor(leaving: me))
        XCTAssertEqual(g.successors(leaving: me).map(\.id), ["+49222000", "u-carol"])
        XCTAssertFalse(g.needsSuccessor(leaving: "+49222000"))
        var alone = g
        alone.members = [GroupMember(number: me, isAdmin: true)]
        XCTAssertFalse(alone.needsSuccessor(leaving: me))
    }

    func testInvitationNeedsPendingEntryAndNoMembership() {
        var g = GroupInfo(json: detailed())
        XCTAssertFalse(g.isInvitation(for: me))
        g.isMember = false
        g.pending = [GroupMember(number: me, uuid: "u-me")]
        XCTAssertTrue(g.isInvitation(for: me))
        g.isTerminated = true
        XCTAssertFalse(g.isInvitation(for: me))
    }

    func testUpdateGroupParameters() {
        let g = GroupInfo(json: detailed())
        XCTAssertEqual(GroupParams.create(name: "New", members: ["+49222000"]) as NSDictionary,
                       ["name": "New", "member": ["+49222000"]] as NSDictionary)
        XCTAssertEqual(GroupParams.create(name: "New", description: "d", members: []) as NSDictionary,
                       ["name": "New", "description": "d"] as NSDictionary)
        XCTAssertEqual(GroupParams.details(from: g, name: "Team", description: "Other") as NSDictionary,
                       ["description": "Other"] as NSDictionary)
        XCTAssertTrue(GroupParams.details(from: g, name: "Team", description: "Plans").isEmpty)
        XCTAssertTrue(GroupParams.details(from: g, name: "").isEmpty) // an empty name is never sent
        XCTAssertEqual(GroupParams.update(groupId: "R1JPVVA=", GroupParams.addMembers(["a"])) as NSDictionary,
                       ["groupId": "R1JPVVA=", "member": ["a"]] as NSDictionary)
        XCTAssertEqual(GroupParams.removeMembers(["a"]) as NSDictionary, ["removeMember": ["a"]] as NSDictionary)
        XCTAssertEqual(GroupParams.promote(["a"]) as NSDictionary, ["admin": ["a"]] as NSDictionary)
        XCTAssertEqual(GroupParams.demote(["a"]) as NSDictionary, ["removeAdmin": ["a"]] as NSDictionary)
        XCTAssertEqual(GroupParams.link(.enabledWithApproval) as NSDictionary, ["link": "enabled-with-approval"] as NSDictionary)
        XCTAssertEqual(GroupParams.resetLink as NSDictionary, ["resetLink": true] as NSDictionary)
        XCTAssertEqual(GroupParams.quit(groupId: "g", successor: "u-bob") as NSDictionary,
                       ["groupId": "g", "admin": ["u-bob"]] as NSDictionary)
        XCTAssertEqual(GroupParams.quit(groupId: "g") as NSDictionary, ["groupId": "g"] as NSDictionary)
    }
}

final class RosterTests: XCTestCase {
    private let me = "+49111000"

    private func conv(_ key: String, incoming: Int = 1, outgoing: Int = 0, group: Bool = false) -> Conversation {
        var c = Conversation(key: key, title: key, isGroup: group)
        for i in 0..<incoming {
            var m = Message()
            m.ts = Int64(100 + i)
            m.text = "hi"
            c.msgs.append(m)
        }
        for i in 0..<outgoing {
            var m = Message()
            m.ts = Int64(200 + i)
            m.text = "yes"
            m.outgoing = true
            c.msgs.append(m)
        }
        return c
    }

    private func roster(contacts: [JSON] = [], groups: [JSON]? = nil, baselined: Bool = true) -> Roster {
        var r = Roster()
        r.account = me
        r.update(contacts: contacts)
        if let groups { r.update(groups: groups) }
        if baselined {
            r.baselineContacts(existing: [])
            r.baselineGroups()
        }
        return r
    }

    private let alice: JSON = ["number": "+49222000", "uuid": "u-alice", "name": "Alice", "isBlocked": false, "isHidden": false]

    func testStrangerWhoWroteFirstIsARequest() {
        let r = roster(contacts: [alice])
        XCTAssertTrue(r.isRequest(conv("+49999000")))
        XCTAssertFalse(r.isRequest(conv("+49222000")), "a contact is not a request")
        XCTAssertFalse(r.isRequest(conv("u-alice")), "a contact addressed by UUID is not a request")
        XCTAssertFalse(r.isRequest(conv("+49999000", incoming: 1, outgoing: 1)), "we wrote to them")
        XCTAssertFalse(r.isRequest(conv("+49999000", incoming: 0)), "an empty chat we started ourselves")
        XCTAssertFalse(r.isRequest(conv(me)), "Note to Self")
    }

    func testAliasResolvesUuidToContact() {
        let r = roster(contacts: [["number": "+49222000", "uuid": "u-alice"]])
        let aliases = ["u-alice": "+49222000"]
        XCTAssertFalse(r.isRequest(conv("u-alice"), resolve: { aliases[$0] ?? $0 }))
    }

    func testNothingIsARequestBeforeTheListsAreKnown() {
        var r = Roster()
        r.account = me
        XCTAssertFalse(r.isRequest(conv("+49999000")))
        r.update(contacts: [alice])
        XCTAssertFalse(r.isRequest(conv("+49999000")), "contacts known but existing chats not grandfathered yet")
        r.baselineContacts(existing: ["+49888000"])
        XCTAssertTrue(r.isRequest(conv("+49999000")))
        XCTAssertFalse(r.isRequest(conv("+49888000")), "existing chat at the first run")
    }

    func testHiddenContactIsStillARequest() {
        let r = roster(contacts: [["number": "+49444000", "uuid": "u-dave", "isHidden": true]])
        XCTAssertTrue(r.isRequest(conv("+49444000")))
        XCTAssertFalse(r.pickableContacts.contains { $0.number == "+49444000" })
    }

    func testAcceptEndsTheRequest() {
        var r = roster()
        XCTAssertTrue(r.isRequest(conv("+49999000")))
        r.accept("+49999000")
        XCTAssertFalse(r.isRequest(conv("+49999000")))
    }

    func testGroupRequests() {
        let member: JSON = ["id": "TUVN", "name": "Member", "isMember": true, "members": [["number": "+49111000", "uuid": "u-me"]]]
        let invite: JSON = ["id": "SU5W", "name": "Invite", "isMember": false,
                            "pendingMembers": [["number": "+49111000", "uuid": "u-me"]]]
        var r = roster(contacts: [], groups: [member], baselined: false)
        r.baselineGroups() // first run: the groups we are in are ours
        r.update(groups: [member, invite, ["id": "TkVX", "name": "New", "isMember": true]])
        XCTAssertFalse(r.isRequest(conv("g:TUVN", group: true)), "grandfathered group")
        XCTAssertTrue(r.isRequest(conv("g:SU5W", incoming: 0, group: true)), "open invitation")
        XCTAssertTrue(r.isRequest(conv("g:TkVX", incoming: 0, group: true)), "added after the first run")
        XCTAssertFalse(r.isRequest(conv("g:TkVX", incoming: 1, outgoing: 1, group: true)), "we wrote in it")
        r.accept("g:TkVX")
        XCTAssertFalse(r.isRequest(conv("g:TkVX", incoming: 0, group: true)))
        XCTAssertFalse(r.isRequest(conv("g:UNKNOWN", group: true)), "group signal-cli does not list")
    }

    func testBlockedStateFromContactsAndGroups() {
        var r = roster(contacts: [["number": "+49333000", "uuid": "u-bad", "isBlocked": true]],
                       groups: [["id": "QkFE", "name": "Bad", "isBlocked": true], ["id": "R09P", "name": "Ok"]])
        XCTAssertTrue(r.isBlocked("+49333000"))
        XCTAssertTrue(r.isBlocked("u-bad"))
        XCTAssertTrue(r.isBlocked("g:QkFE"))
        XCTAssertFalse(r.isBlocked("g:R09P"))
        // A blocked chat is not a request, but nothing can be sent and nothing makes noise.
        let c = conv("+49333000")
        XCTAssertFalse(r.isRequest(c))
        XCTAssertTrue(r.isSendLocked(c))
        XCTAssertTrue(r.isQuiet(c))
        XCTAssertFalse(r.mayAcknowledge(c))
        // Unblocking on the next list.
        r.update(contacts: [["number": "+49333000", "uuid": "u-bad", "isBlocked": false]])
        XCTAssertFalse(r.isBlocked("u-bad"))
    }

    func testBlockedSenderInAnotherwiseNormalGroupIsQuiet() {
        var r = roster(contacts: [["number": "+49333000", "isBlocked": true]],
                       groups: [["id": "R09P", "name": "Ok", "isMember": true]])
        r.accept("g:R09P")
        let g = conv("g:R09P", group: true)
        XCTAssertFalse(r.isQuiet(g, author: "+49222000"))
        XCTAssertTrue(r.isQuiet(g, author: "+49333000"))
        XCTAssertFalse(r.isSendLocked(g))
    }

    func testRequestsAreQuietAndLocked() {
        let r = roster()
        let c = conv("+49999000")
        XCTAssertTrue(r.isQuiet(c))
        XCTAssertTrue(r.isSendLocked(c))
        XCTAssertFalse(r.mayAcknowledge(c), "no read receipts before the request is accepted")
        let normal = conv("+49999000", incoming: 1, outgoing: 1)
        XCTAssertFalse(r.isQuiet(normal))
        XCTAssertFalse(r.isSendLocked(normal))
        XCTAssertTrue(r.mayAcknowledge(normal))
    }

    func testLeftGroupLocksTheComposer() {
        let r = roster(groups: [["id": "R09P", "name": "Gone", "isMember": false]])
        XCTAssertTrue(r.isSendLocked(conv("g:R09P", group: true)))
    }

    func testLocalBlockUpdateCoversNumberAndUuid() {
        var r = roster(contacts: [["number": "+49222000", "uuid": "u-alice"]])
        r.setBlocked("u-alice", true, resolve: { $0 == "u-alice" ? "+49222000" : $0 })
        XCTAssertTrue(r.isBlocked("+49222000"))
        XCTAssertTrue(r.isBlocked("u-alice"))
        r.setBlocked("+49222000", false)
        XCTAssertFalse(r.isBlocked("u-alice"))
    }

    func testPersistenceIsPerAccount() throws {
        let suite = "corvus-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var r = roster(contacts: [["number": "+49333000", "isBlocked": true]], baselined: false)
        r.baselineContacts(existing: ["+49888000", "g:SKIP"])
        r.accept("+49999000")
        r.save(defaults: defaults)

        var again = Roster()
        again.load(account: me, defaults: defaults)
        XCTAssertEqual(again.accepted, ["+49888000", "+49999000"])
        XCTAssertTrue(again.blocked.contains("+49333000"))
        XCTAssertTrue(again.contactsBaselined)
        XCTAssertFalse(again.groupsBaselined)

        var other = Roster()
        other.load(account: "+49000111", defaults: defaults)
        XCTAssertTrue(other.accepted.isEmpty)
        XCTAssertFalse(other.contactsBaselined)
    }

    func testRpcParameters() {
        XCTAssertEqual(RequestParams.block(key: "+49222000") as NSDictionary, ["recipient": ["+49222000"]] as NSDictionary)
        XCTAssertEqual(RequestParams.block(key: "g:R09P") as NSDictionary, ["groupId": ["R09P"]] as NSDictionary)
        XCTAssertEqual(RequestParams.response(.accept, key: "+49222000") as NSDictionary,
                       ["type": "accept", "recipient": ["+49222000"]] as NSDictionary)
        XCTAssertEqual(RequestParams.response(.delete, key: "g:R09P") as NSDictionary,
                       ["type": "delete", "groupId": "R09P"] as NSDictionary)
    }
}

/// The group / block / request methods against tests/mock-signal-cli.py (same shapes as signal-cli 0.14).
@MainActor
final class GroupRpcTests: XCTestCase {
    private func mock() throws -> String {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("../../../tests/mock-signal-cli.py").standardized
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("mock-signal-cli-\(UUID().uuidString).py")
        try FileManager.default.copyItem(at: source, to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        return target.path
    }

    func testGroupLifecycleBlockAndRequestResponse() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"), "python3 missing")
        let cli = SignalCli()
        cli.executable = try mock()
        defer { try? FileManager.default.removeItem(atPath: cli.executable) }
        cli.start(account: "+491234567")
        defer { cli.stop() }

        // create (updateGroup without groupId)
        let created = try await cli.call("updateGroup", GroupParams.create(name: "Fresh", description: "About", members: ["+49111", "+49222"]))
        let id = jsonString(jsonObject(created)["groupId"])
        XCTAssertFalse(id.isEmpty)
        func load() async throws -> GroupInfo {
            let list = GroupInfo.parseList(try await cli.call("listGroups", ["groupId": [id]]))
            return try XCTUnwrap(list.first)
        }
        var g = try await load()
        XCTAssertEqual(g.name, "Fresh")
        XCTAssertEqual(g.description, "About")
        XCTAssertEqual(g.members.map(\.id).sorted(), ["+49111", "+491234567", "+49222"])
        XCTAssertTrue(g.isAdmin("+491234567"))

        // rename / description / promote / demote / remove / add
        try await cli.call("updateGroup", GroupParams.update(groupId: id, GroupParams.details(from: g, name: "Renamed", description: "New text")))
        try await cli.call("updateGroup", GroupParams.update(groupId: id, GroupParams.promote(["+49111"])))
        g = try await load()
        XCTAssertEqual(g.name, "Renamed")
        XCTAssertEqual(g.description, "New text")
        XCTAssertTrue(g.isAdmin("+49111"))
        try await cli.call("updateGroup", GroupParams.update(groupId: id, GroupParams.demote(["+49111"])))
        try await cli.call("updateGroup", GroupParams.update(groupId: id, GroupParams.removeMembers(["+49222"])))
        try await cli.call("updateGroup", GroupParams.update(groupId: id, GroupParams.addMembers(["+49555"])))
        g = try await load()
        XCTAssertFalse(g.isAdmin("+49111"))
        XCTAssertNil(g.member("+49222"))
        XCTAssertNotNil(g.member("+49555"))

        // invite link
        try await cli.call("updateGroup", GroupParams.update(groupId: id, GroupParams.link(.enabled)))
        g = try await load()
        XCTAssertTrue(g.inviteLinkEnabled)
        let first = g.inviteLink
        try await cli.call("updateGroup", GroupParams.update(groupId: id, GroupParams.resetLink))
        g = try await load()
        XCTAssertNotEqual(g.inviteLink, first)
        try await cli.call("updateGroup", GroupParams.update(groupId: id, GroupParams.link(.disabled)))
        g = try await load()
        XCTAssertFalse(g.inviteLinkEnabled)

        // blocking a group and a contact
        try await cli.call("block", RequestParams.block(key: "g:" + id))
        g = try await load()
        XCTAssertTrue(g.isBlocked)
        try await cli.call("unblock", RequestParams.block(key: "g:" + id))
        g = try await load()
        XCTAssertFalse(g.isBlocked)
        try await cli.call("block", RequestParams.block(key: "+49111"))
        var roster = Roster()
        roster.update(contacts: try await cli.call("listContacts"))
        XCTAssertTrue(roster.isBlocked("+49111"))
        try await cli.call("unblock", RequestParams.block(key: "+49111"))
        roster.update(contacts: try await cli.call("listContacts"))
        XCTAssertFalse(roster.isBlocked("+49111"))

        // message request responses: lowercase types only, like signal-cli
        try await cli.call("sendMessageRequestResponse", RequestParams.response(.accept, key: "+49444"))
        try await cli.call("sendMessageRequestResponse", RequestParams.response(.delete, key: "g:" + id))
        do {
            try await cli.call("sendMessageRequestResponse", ["type": "ACCEPT", "recipient": ["+49444"]])
            XCTFail("uppercase type must be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("--type"))
        }

        // leaving: we are the only admin and others remain, so a successor is required
        g = try await load()
        XCTAssertTrue(g.needsSuccessor(leaving: "+491234567"))
        do {
            try await cli.call("quitGroup", GroupParams.quit(groupId: id))
            XCTFail("the only admin must name a successor")
        } catch {}
        try await cli.call("quitGroup", GroupParams.quit(groupId: id, successor: "+49555"))
        g = try await load()
        XCTAssertFalse(g.isMember)
    }
}
