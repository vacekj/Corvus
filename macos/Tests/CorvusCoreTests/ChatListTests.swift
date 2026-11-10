import XCTest
@testable import CorvusCore

final class StickerPackLinkTests: XCTestCase {
    private let id = String(repeating: "a1", count: 16)
    private let key = String(repeating: "0f", count: 32)

    func testParsesWebAndAppLinks() {
        let web = StickerPackLink.parse("https://signal.art/addstickers/#pack_id=\(id)&pack_key=\(key)")
        XCTAssertEqual(web, StickerPackLink(packId: id, packKey: key))
        let app = StickerPackLink.parse("sgnl://addstickers/?pack_key=\(key)&pack_id=\(id)")
        XCTAssertEqual(app, web)
        XCTAssertEqual(web?.uri, "https://signal.art/addstickers/#pack_id=\(id)&pack_key=\(key)")
        // Upper-case hex and surrounding white space are accepted.
        XCTAssertEqual(StickerPackLink.parse("  https://signal.art/addstickers/#pack_id=\(id.uppercased())&pack_key=\(key)\n"), web)
    }

    func testRejectsOtherInput() {
        XCTAssertNil(StickerPackLink.parse(""))
        XCTAssertNil(StickerPackLink.parse("https://example.com/addstickers/#pack_id=\(id)&pack_key=\(key)"))
        XCTAssertNil(StickerPackLink.parse("https://signal.art/addstickers/#pack_id=\(id)"))
        XCTAssertNil(StickerPackLink.parse("https://signal.art/addstickers/#pack_id=xyz&pack_key=\(key)"))
        XCTAssertNil(StickerPackLink.parse("https://signal.art/addstickers/#pack_id=\(id)&pack_key=\(key.dropLast())"))
    }

    func testFindsLinkInPastedText() {
        let text = "Look at these: https://signal.art/addstickers/#pack_id=\(id)&pack_key=\(key) nice"
        XCTAssertEqual(StickerPackLink.find(in: text)?.packId, id)
        XCTAssertNil(StickerPackLink.find(in: "no link here"))
    }
}

final class PassphrasePolicyTests: XCTestCase {
    func testValidation() {
        XCTAssertEqual(PassphrasePolicy.problem(new: "", repeated: ""), "")
        XCTAssertEqual(PassphrasePolicy.problem(new: "short", repeated: "short"), "Use at least 8 characters.")
        XCTAssertEqual(PassphrasePolicy.problem(new: "long enough", repeated: ""), "")
        XCTAssertEqual(PassphrasePolicy.problem(new: "long enough", repeated: "long enougH"), "The passphrases do not match.")
        XCTAssertNil(PassphrasePolicy.problem(new: "long enough", repeated: "long enough"))
        XCTAssertTrue(PassphrasePolicy.isAcceptable(new: "12345678", repeated: "12345678"))
        XCTAssertFalse(PassphrasePolicy.isAcceptable(new: "1234567", repeated: "1234567"))
    }
}

final class DraftPreviewTests: XCTestCase {
    func testDraftText() {
        XCTAssertNil(DraftPreview.text(""))
        XCTAssertNil(DraftPreview.text("  \n "))
        XCTAssertEqual(DraftPreview.text("hello\nworld"), "Draft: hello world")
        XCTAssertEqual(DraftPreview.text("", attachments: 1), "Draft: 📎 Attachment")
        XCTAssertEqual(DraftPreview.text("", attachments: 3), "Draft: 📎 3 attachments")
        XCTAssertEqual(DraftPreview.text(String(repeating: "x", count: 500))?.count, "Draft: ".count + 200)
    }
}

final class PinnedChatTests: XCTestCase {
    private func message(_ ts: Int64) -> Message {
        var m = Message()
        m.ts = ts
        m.text = "m\(ts)"
        m.orderTs = nowMs() + ts * 60_000 // later arrivals sort first
        return m
    }

    func testPinnedChatsComeFirstAndArePersisted() {
        var s = ChatState()
        _ = s.addMessage("a", message(1))
        _ = s.addMessage("b", message(2))
        _ = s.addMessage("c", message(3))
        XCTAssertEqual(s.sortedConversations(archived: false).map(\.key), ["c", "b", "a"])
        s.convs["a"]!.pinned = true
        s.convs["b"]!.markedUnread = true
        XCTAssertEqual(s.sortedConversations(archived: false).map(\.key), ["a", "c", "b"])

        var loaded = ChatState()
        loaded.loadHistory(s.allRecords())
        XCTAssertTrue(loaded.convs["a"]!.pinned)
        XCTAssertFalse(loaded.convs["c"]!.pinned)
        XCTAssertTrue(loaded.convs["b"]!.markedUnread)

        // Later records win (unpin, mark read).
        loaded.loadHistory([Records.pin("a", false), Records.markedUnread("b", false)])
        XCTAssertFalse(loaded.convs["a"]!.pinned)
        XCTAssertFalse(loaded.convs["b"]!.markedUnread)
    }

    func testLaunchSnapshotKeepsTheTopChatsAndTheirNewestMessages() {
        var s = ChatState()
        s.loadHistory([Records.name("+1", "One")])
        for (key, base) in [("+1", 1_000), ("+2", 2_000), ("+3", 3_000)] as [(String, Int64)] {
            for i in 0..<5 { _ = s.addMessage(key, message(base + Int64(i))) }
        }
        s.convs["+1"]!.pinned = true

        var loaded = ChatState()
        loaded.loadHistory(s.snapshotRecords(recentChats: 2, messages: 2))
        // Pinned first, then the most recent: +1 and +3; +2 comes with the full history.
        XCTAssertEqual(Set(loaded.convs.keys), ["+1", "+3"])
        XCTAssertEqual(loaded.convs["+3"]!.msgs.map(\.ts), [3_003, 3_004])
        XCTAssertEqual(loaded.convs["+1"]!.title, "One")
        XCTAssertTrue(loaded.convs["+1"]!.pinned)
    }
}
