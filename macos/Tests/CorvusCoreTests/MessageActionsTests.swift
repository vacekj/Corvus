import XCTest
@testable import CorvusCore

private let me = "+15550100"
private let peer = "+15550101"
private let peerUuid = "00000000-0000-4000-8000-000000000101"

private func message(_ ts: Int64, outgoing: Bool = false, text: String = "hi") -> Message {
    var m = Message()
    m.ts = ts
    m.text = text
    m.outgoing = outgoing
    m.authorKey = outgoing ? me : peer
    return m
}

private func state(_ msgs: [Message]) -> ChatState {
    var s = ChatState()
    s.account = me
    s.alias[peerUuid] = peer
    s.ensure(peer, title: "Peer")
    for m in msgs { s.convs[peer]!.insertSorted(m) }
    return s
}

final class PinEnvelopeTests: XCTestCase {
    func testParsesPinAndUnpin() {
        let pin = parseEnvelope(["sourceNumber": peer, "timestamp": 900, "dataMessage": [
            "timestamp": 1000,
            "pinMessage": ["targetAuthor": me, "targetAuthorNumber": me, "targetAuthorUuid": "", "targetSentTimestamp": 5,
                           "pinDurationSeconds": 86400] as JSON,
        ] as JSON])
        XCTAssertEqual(pin.kind, .pin)
        XCTAssertEqual(pin.targetNumber, me)
        XCTAssertEqual(pin.targetTs, 5)
        XCTAssertEqual(pin.pinDurationSeconds, 86400)
        XCTAssertEqual(pin.msg.ts, 1000)

        let unpin = parseEnvelope(["sourceNumber": peer, "dataMessage": [
            "timestamp": 1100, "groupInfo": ["groupId": "abc"] as JSON,
            "unpinMessage": ["targetAuthorUuid": peerUuid, "targetSentTimestamp": 7] as JSON,
        ] as JSON])
        XCTAssertEqual(unpin.kind, .unpin)
        XCTAssertEqual(unpin.targetUuid, peerUuid)
        XCTAssertEqual(unpin.targetTs, 7)
        XCTAssertEqual(unpin.groupId, "abc")

        // From another of our own devices (sync)
        let sync = parseEnvelope(["sourceNumber": me, "syncMessage": ["sentMessage": [
            "destinationNumber": peer, "timestamp": 1200,
            "pinMessage": ["targetAuthorNumber": peer, "targetSentTimestamp": 9, "pinDurationSeconds": -1] as JSON,
        ] as JSON] as JSON])
        XCTAssertEqual(sync.kind, .pin)
        XCTAssertTrue(sync.outgoing)
        XCTAssertEqual(sync.destination, peer)
        XCTAssertEqual(sync.pinDurationSeconds, -1)

        // No target: ignored
        XCTAssertEqual(parseEnvelope(["sourceNumber": peer, "dataMessage": ["pinMessage": ["targetAuthor": me] as JSON] as JSON]).kind, .none)
    }
}

final class PinTests: XCTestCase {
    func testPinUnpinAndPersistence() {
        var s = state([message(1), message(2, outgoing: true)])
        // Pinned by uuid: the alias resolves to the stored number
        let recs = s.applyPin(peer, targetTs: 1, authors: [peerUuid], atMs: 100, durationSeconds: 60)
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(s.convs[peer]!.pins, [MessagePin(ts: 1, authorKey: peer, pinnedAtMs: 100, expiresMs: 60_100)])
        XCTAssertEqual(s.activePins(peer, now: 200).map(\.message.ts), [1])
        XCTAssertTrue(s.activePins(peer, now: 60_100).isEmpty) // expired
        // Redelivery or an older pin: nothing changes
        XCTAssertTrue(s.applyPin(peer, targetTs: 1, authors: [peer], atMs: 100, durationSeconds: 60).isEmpty)

        _ = s.applyPin(peer, targetTs: 2, authors: [me], atMs: 150, durationSeconds: -1)
        XCTAssertEqual(s.activePins(peer, now: 200).map(\.message.ts), [2, 1]) // newest first

        // Reloading the records (message records + pin updates) gives the same pins
        var loaded = ChatState()
        loaded.account = me
        loaded.loadHistory(s.allRecords())
        XCTAssertEqual(loaded.convs[peer]!.pins, s.convs[peer]!.pins)

        var log = [Records.message(peer, message(1)), Records.message(peer, message(2, outgoing: true))]
        log += recs
        log.append(s.applyUnpin(peer, targetTs: 1, authors: [peer])!)
        XCTAssertNil(s.applyUnpin(peer, targetTs: 1, authors: [peer]))
        var replayed = ChatState()
        replayed.account = me
        replayed.loadHistory(log)
        XCTAssertTrue(replayed.convs[peer]!.pins.isEmpty)
        XCTAssertEqual(replayed.convs[peer]!.msgs[0].pinnedAtMs, 0)
    }

    func testAtMostThreePinsOldestDropped() {
        var s = state((1...4).map { message(Int64($0)) })
        for ts in 1...3 { _ = s.applyPin(peer, targetTs: Int64(ts), authors: [peer], atMs: Int64(ts) * 10, durationSeconds: -1) }
        let recs = s.applyPin(peer, targetTs: 4, authors: [peer], atMs: 40, durationSeconds: -1)
        XCTAssertEqual(recs.count, 2) // the new pin and the unpin of the oldest
        XCTAssertEqual(s.convs[peer]!.pins.map(\.ts), [2, 3, 4])
        XCTAssertEqual(s.convs[peer]!.msgs[0].pinnedAtMs, 0)
    }

    func testDeletedMessagesAreNotPinned() {
        var s = state([message(1)])
        _ = s.applyPin(peer, targetTs: 1, authors: [peer], atMs: 10, durationSeconds: -1)
        _ = s.applyDelete(peer, targetTs: 1, authors: [peer])
        XCTAssertTrue(s.activePins(peer, now: 20).isEmpty)
        XCTAssertTrue(s.applyPin(peer, targetTs: 1, authors: [peer], atMs: 30, durationSeconds: -1).isEmpty)
        XCTAssertNil((Records.message(peer, s.convs[peer]!.msgs[0])["d"] as? JSON)?["pn"])
    }

    func testRestoreSnapshot() {
        var s = state([message(1), message(2), message(3), message(4)])
        for ts in 1...3 { _ = s.applyPin(peer, targetTs: Int64(ts), authors: [peer], atMs: Int64(ts) * 10, durationSeconds: -1) }
        let before = s.pinSnapshot(peer)
        _ = s.applyPin(peer, targetTs: 4, authors: [peer], atMs: 40, durationSeconds: -1) // drops 1
        s.restorePins(peer, before)
        XCTAssertEqual(s.convs[peer]!.pins, before)
        XCTAssertEqual(s.convs[peer]!.msgs.map(\.pinnedAtMs), [10, 20, 30, 0])
    }
}

final class FailedSendTests: XCTestCase {
    private func pendingState() -> ChatState {
        var s = state([message(1)])
        var preview = message(50, outgoing: true, text: "unsent")
        preview.orderTs = 50
        s.convs[peer]!.insertSorted(preview)
        var p = PendingSend()
        p.conversationKey = peer
        p.temporaryTimestamp = 50
        p.message = preview
        s.pendingSends["send-1"] = p
        return s
    }

    func testFailedSendStaysAndIsPersisted() {
        var s = pendingState()
        let rec = s.failPendingSend("send-1")
        XCTAssertNotNil(rec)
        XCTAssertTrue(s.pendingSends.isEmpty)
        XCTAssertTrue(s.convs[peer]!.msgs[1].sendFailed)
        XCTAssertFalse(s.convs[peer]!.msgs[1].canEdit(nowMs: 60))

        var loaded = ChatState()
        loaded.account = me
        loaded.loadHistory([rec!])
        XCTAssertTrue(loaded.convs[peer]!.msgs[0].sendFailed)
        XCTAssertEqual(loaded.convs[peer]!.msgs[0].text, "unsent")
        // Incoming messages never count as failed
        var incoming = message(3)
        incoming.sendFailed = true
        XCTAssertNil(Records.message(peer, incoming)["d"])
    }

    func testRetrySucceedsWithNewTimestamp() {
        var s = pendingState()
        _ = s.failPendingSend("send-1")
        XCTAssertNil(s.beginRetry(peer, ts: 1)) // not a failed message
        let id = s.beginRetry(peer, ts: 50, id: "retry-1")
        XCTAssertEqual(id, "retry-1")
        XCTAssertFalse(s.convs[peer]!.msgs[1].sendFailed)
        XCTAssertTrue(s.isPendingPreview(peer, ts: 50))
        _ = s.finalizePendingSend("retry-1", timestamp: 70)
        XCTAssertEqual(s.convs[peer]!.msgs.map(\.ts), [1, 70])
        XCTAssertFalse(s.convs[peer]!.msgs[1].sendFailed)
        XCTAssertTrue(s.pendingSends.isEmpty)
        // The rewrite after a retry holds the sent message only
        let records = s.allRecords().filter { jsonString($0["t"]) == "m" }
        XCTAssertEqual(records.map { jsonInt64($0["ts"]) }, [1, 70])
    }

    func testRetryFailsAgain() {
        var s = pendingState()
        _ = s.failPendingSend("send-1")
        let id = s.beginRetry(peer, ts: 50)!
        XCTAssertNil(s.allRecords().first { jsonInt64($0["ts"]) == 50 }) // pending: not in a rewrite
        _ = s.failPendingSend(id)
        XCTAssertTrue(s.convs[peer]!.msgs[1].sendFailed)
        XCTAssertNotNil(s.allRecords().first { jsonInt64($0["ts"]) == 50 })
    }

    func testRetryParams() {
        var m = message(50, outgoing: true, text: "bold \u{FFFC}")
        m.textStyles = [TextStyleRange(start: 0, length: 4, style: "BOLD")]
        m.mentions = [MentionRange(start: 5, length: 1, uuid: peerUuid), MentionRange(start: 0, length: 1, uuid: "")]
        m.quote.valid = true
        m.quote.id = 1
        m.quote.authorKey = peer
        m.quote.text = "hi"
        var file = Attachment()
        file.path = "/tmp/a.png"
        m.attachments = [file]
        let p = RetrySend.params(m)
        XCTAssertEqual(p["message"] as? String, "bold \u{FFFC}")
        XCTAssertEqual(p["textStyle"] as? [String], ["0:4:BOLD"])
        XCTAssertEqual(p["mention"] as? [String], ["5:1:\(peerUuid)"])
        XCTAssertEqual(p["quoteTimestamp"] as? Int64, 1)
        XCTAssertEqual(p["quoteAuthor"] as? String, peer)
        XCTAssertNil(p["sticker"])
        XCTAssertEqual(RetrySend.attachmentPaths(m), ["/tmp/a.png"])

        var sticker = message(51, outgoing: true, text: "")
        sticker.attachments = [Attachment.sticker(packId: "abcd", stickerId: 3)]
        XCTAssertEqual(RetrySend.params(sticker)["sticker"] as? String, "abcd:3")
        XCTAssertNil(RetrySend.params(sticker)["message"])
        XCTAssertTrue(RetrySend.attachmentPaths(sticker).isEmpty)
    }
}

final class SelectionRulesTests: XCTestCase {
    func testDeleteForEveryoneNeedsOwnRecentMessages() {
        let now: Int64 = 100_000_000
        let own = message(now - 1000, outgoing: true)
        let old = message(now - MessageSelectionRules.deleteForEveryoneWindowMs - 1, outgoing: true)
        var failed = message(now - 10, outgoing: true)
        failed.sendFailed = true
        var deleted = message(now - 10, outgoing: true)
        deleted.markDeleted()
        XCTAssertTrue(MessageSelectionRules.canDeleteForEveryone([own], now: now))
        XCTAssertFalse(MessageSelectionRules.canDeleteForEveryone([own, message(now - 10)], now: now)) // a peer's
        XCTAssertFalse(MessageSelectionRules.canDeleteForEveryone([own, old], now: now))
        XCTAssertFalse(MessageSelectionRules.canDeleteForEveryone([own, failed], now: now))
        XCTAssertFalse(MessageSelectionRules.canDeleteForEveryone([own, deleted], now: now))
        XCTAssertFalse(MessageSelectionRules.canDeleteForEveryone([], now: now))
    }

    func testForward() {
        var poll = message(1)
        poll.poll.question = "Q"
        poll.poll.options = ["a", "b"]
        var failed = message(2, outgoing: true)
        failed.sendFailed = true
        XCTAssertTrue(MessageSelectionRules.canForward([message(1), message(3, outgoing: true)]))
        XCTAssertFalse(MessageSelectionRules.canForward([message(1), poll]))
        XCTAssertFalse(MessageSelectionRules.canForward([failed]))
        XCTAssertFalse(MessageSelectionRules.canForward([message(1, text: "")]))
        XCTAssertFalse(MessageSelectionRules.canInteract(failed))
    }
}
