import XCTest
@testable import CorvusCore

private func msg(_ ts: Int64, _ text: String, file: String = "", type: String = "") -> Message {
    var m = Message()
    m.ts = ts
    m.text = text
    m.authorKey = "author"
    if !file.isEmpty || !type.isEmpty {
        var a = Attachment()
        a.filename = file
        a.contentType = type
        m.attachments = [a]
    }
    return m
}

final class ChatSearchTests: XCTestCase {
    func testMatchesOldestFirstAndStartsAtNewest() {
        let msgs = [msg(1, "Hello there"), msg(2, "nothing"), msg(3, "say hello"), msg(4, "x", file: "hello.pdf")]
        let ids = ChatSearch.matches(msgs, "  HELLO ")!
        XCTAssertEqual(ids, [msgs[0].id, msgs[2].id, msgs[3].id])
        XCTAssertEqual(ChatSearch.position(in: ids, keeping: nil), 2)
        XCTAssertEqual(ChatSearch.position(in: ids, keeping: msgs[0].id), 0)   // refresh keeps the selected match
        XCTAssertEqual(ChatSearch.position(in: ids, keeping: msgs[1].id), 2)   // no longer a match: newest
        XCTAssertEqual(ChatSearch.position(in: [], keeping: nil), -1)
        XCTAssertEqual(ChatSearch.matches(msgs, " "), [])
    }

    func testPreviousGoesToOlderAndWraps() {
        XCTAssertEqual(ChatSearch.step(2, count: 3, backwards: true), 1)
        XCTAssertEqual(ChatSearch.step(0, count: 3, backwards: true), 2)
        XCTAssertEqual(ChatSearch.step(2, count: 3, backwards: false), 0)
        XCTAssertEqual(ChatSearch.step(0, count: 0, backwards: false), -1)
    }

    func testCancelledSearchReturnsNil() async {
        let msgs = (0..<2000).map { msg(Int64($0), "text \($0)") }
        let t = Task.detached { () -> [String]? in
            withUnsafeCurrentTask { $0?.cancel() }
            return ChatSearch.matches(msgs, "text")
        }
        let found = await t.value
        XCTAssertNil(found)
    }
}

final class MediaGalleryTests: XCTestCase {
    func testGroupsNewestFirstAndSkipsStickersDeletedAndViewOnce() {
        var deleted = msg(5, "https://example.org/gone", file: "d.png", type: "image/png")
        deleted.deleted = true
        var once = msg(6, "", file: "o.jpg", type: "image/jpeg")
        once.viewOnce = true
        let msgs = [
            msg(1, "see https://example.org/a and ftp://example.org/b", file: "a.png", type: "image/png"),
            msg(2, "", file: "v.mp4", type: "video/mp4"),
            msg(3, "", file: "n.m4a", type: "audio/mp4"),
            msg(4, "", file: "r.pdf", type: "application/pdf"),
            msg(7, "", file: Attachment.stickerPrefix + "s", type: "image/webp"),
            deleted, once,
        ]
        let g = MediaGallery(msgs)
        XCTAssertEqual(g.media.map(\.message.ts), [2, 1])
        XCTAssertEqual(g.audio.map(\.message.ts), [3])
        XCTAssertEqual(g.files.map(\.message.ts), [4])
        XCTAssertEqual(g.links.map(\.url.absoluteString), ["https://example.org/a"])
    }
}

final class HistoryWriterTests: XCTestCase {
    func testWritesRunInOrderOffTheCallingThread() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("history.db").path
        let key = HistoryKey.random()

        let writer = HistoryWriter()
        try writer.db.create(path: path, key: key)
        var s = ChatState()
        for ts in Int64(1)...3 {
            _ = s.addMessage("conv", msg(ts, "m\(ts)"))!
            writer.sync(s)
        }
        // Delete the second message: the write works on a snapshot, later changes land after it.
        s.convs["conv"]!.msgs.remove(at: 1)
        let removed = expectation(description: "removed")
        writer.sync(s, force: true) { error in
            XCTAssertNil(error)
            XCTAssertTrue(Thread.isMainThread)
            removed.fulfill()
        }
        _ = s.addMessage("conv", msg(4, "m4"))!
        let added = expectation(description: "added")
        writer.sync(s) { error in XCTAssertNil(error); added.fulfill() }
        wait(for: [removed, added], timeout: 10)
        writer.drain()
        writer.db.close()

        let db = HistoryDB()
        try db.open(path: path, key: key)
        XCTAssertEqual(try db.load()["conv"]?.msgs.map(\.text), ["m1", "m3", "m4"])
    }

    func testFailureIsReported() {
        let writer = HistoryWriter() // never opened
        let failed = expectation(description: "error")
        var s = ChatState()
        _ = s.addMessage("conv", msg(1, "m"))
        writer.sync(s) { error in
            XCTAssertNotNil(error)
            failed.fulfill()
        }
        wait(for: [failed], timeout: 10)
    }
}
