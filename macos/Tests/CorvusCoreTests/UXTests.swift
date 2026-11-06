import XCTest
@testable import CorvusCore

final class FuzzyMatchTests: XCTestCase {
    func testOrderAndRanking() {
        XCTAssertNil(FuzzyMatch.score("xyz", "Alice"))
        XCTAssertNil(FuzzyMatch.score("eca", "Alice")) // order matters
        XCTAssertEqual(FuzzyMatch.score("", "Alice"), 0)
        let prefix = FuzzyMatch.score("al", "Alice")!
        let word = FuzzyMatch.score("al", "Book Club Alpha")!
        let inside = FuzzyMatch.score("al", "Natalie")!
        let scattered = FuzzyMatch.score("ae", "Alice")!
        XCTAssertGreaterThan(prefix, word)
        XCTAssertGreaterThan(word, inside)
        XCTAssertGreaterThan(inside, scattered)
        // initials of words beat letters inside words
        XCTAssertGreaterThan(FuzzyMatch.score("bc", "Book Club")!, FuzzyMatch.score("bc", "Abacus")!)
    }

    func testIgnoresCaseAndDiacritics() {
        XCTAssertNotNil(FuzzyMatch.score("zlu", "Žluťoučký kůň"))
        XCTAssertNotNil(FuzzyMatch.score("ANNA", "anna"))
        XCTAssertNotNil(FuzzyMatch.score("a b", "Ab")) // spaces in the query are ignored
    }
}

final class MessageSearchTests: XCTestCase {
    private func msg(_ ts: Int64, _ text: String, outgoing: Bool = false) -> Message {
        var m = Message()
        m.ts = ts
        m.text = text
        m.outgoing = outgoing
        m.authorKey = outgoing ? "me" : "u-1"
        return m
    }

    func testFindsNewestFirstAcrossChats() {
        var a = Conversation(key: "u-1", title: "A")
        a.msgs = [msg(1, "Lunch tomorrow?"), msg(5, "no match"), msg(9, "LUNCH at noon", outgoing: true)]
        var b = Conversation(key: "g:x", title: "B", isGroup: true)
        b.msgs = [msg(7, "lunch was great")]
        var deleted = msg(10, "lunch deleted")
        deleted.deleted = true
        b.msgs.append(deleted)
        let hits = searchMessages(["u-1": a, "g:x": b], query: "lunch")
        XCTAssertEqual(hits.map(\.ts), [9, 7, 1])
        XCTAssertEqual(hits.map(\.key), ["u-1", "g:x", "u-1"])
        XCTAssertTrue(hits[0].outgoing)
        XCTAssertTrue(searchMessages(["u-1": a], query: "l").isEmpty) // too short
        XCTAssertEqual(searchMessages(["u-1": a, "g:x": b], query: "lunch", limit: 2).count, 2)
    }

    func testDiacriticsAndSnippet() {
        var a = Conversation(key: "u-1")
        let long = String(repeating: "word ", count: 20) + "káva\nnext line"
        a.msgs = [msg(1, long)]
        let hit = searchMessages(["u-1": a], query: "kava").first
        XCTAssertNotNil(hit)
        XCTAssertTrue(hit!.snippet.hasPrefix("…"))
        XCTAssertTrue(hit!.snippet.contains("káva next line"))
        XCTAssertLessThan(hit!.snippet.count, long.count)
    }
}

final class TypingTests: XCTestCase {
    func testParse() {
        let e = parseTyping(["sourceUuid": "u-1", "timestamp": 5,
                             "typingMessage": ["action": "STARTED", "timestamp": 7, "groupId": "grp"] as JSON])
        XCTAssertEqual(e, TypingEvent(sender: "u-1", groupId: "grp", started: true, timestamp: 7))
        XCTAssertEqual(parseTyping(["sourceNumber": "n-1", "typingMessage": ["action": "STOPPED"] as JSON])?.started, false)
        XCTAssertNil(parseTyping(["sourceNumber": "n-1", "dataMessage": ["message": "hi"] as JSON]))
        // A typing envelope is not a message.
        XCTAssertEqual(parseEnvelope(["sourceNumber": "n-1", "typingMessage": ["action": "STARTED"] as JSON]).kind, .none)
    }

    func testTrackerExpiresAndClears() {
        var t = TypingTracker()
        XCTAssertTrue(t.apply(conversation: "c", typer: "b", started: true, now: 0))
        XCTAssertFalse(t.apply(conversation: "c", typer: "b", started: true, now: 1000)) // refresh only
        t.apply(conversation: "c", typer: "a", started: true, now: 2000)
        XCTAssertEqual(t.typers(in: "c"), ["a", "b"])
        XCTAssertTrue(t.expire(now: 16_000)) // b refreshed at 1000
        XCTAssertEqual(t.typers(in: "c"), ["a"])
        XCTAssertTrue(t.clear(conversation: "c", typer: "a"))
        XCTAssertTrue(t.isEmpty)
        t.apply(conversation: "c", typer: "a", started: true, now: 0)
        XCTAssertTrue(t.apply(conversation: "c", typer: "a", started: false, now: 1))
        XCTAssertTrue(t.isEmpty)
    }

    func testOutbox() {
        var o = TypingOutbox()
        XCTAssertEqual(o.edited(conversation: "c", empty: false, allowed: true, now: 0), [.start("c")])
        XCTAssertEqual(o.edited(conversation: "c", empty: false, allowed: true, now: 3000), [])
        XCTAssertEqual(o.tick(now: 7000), []) // 4 s since the last keystroke
        XCTAssertEqual(o.edited(conversation: "c", empty: false, allowed: true, now: 10_000), [.start("c")]) // refresh
        XCTAssertEqual(o.tick(now: 15_000), [.stop("c")])
        XCTAssertEqual(o.tick(now: 30_000), [])
        // switching chats stops the old one
        _ = o.edited(conversation: "c", empty: false, allowed: true, now: 40_000)
        XCTAssertEqual(o.edited(conversation: "d", empty: false, allowed: true, now: 41_000), [.stop("c"), .start("d")])
        // emptied field
        XCTAssertEqual(o.edited(conversation: "d", empty: true, allowed: true, now: 42_000), [.stop("d")])
        // not allowed (message request not accepted): nothing is sent
        XCTAssertEqual(o.edited(conversation: "e", empty: false, allowed: false, now: 43_000), [])
        _ = o.edited(conversation: "e", empty: false, allowed: true, now: 44_000)
        XCTAssertEqual(o.reset(), [.stop("e")])
        XCTAssertEqual(o.reset(), [])
    }
}

final class ComposerEditingTests: XCTestCase {
    private func apply(_ marker: String, _ text: String, _ sel: NSRange) -> (String, NSRange) {
        let r = toggleMarker(marker, text: text, selection: sel)
        return ((text as NSString).replacingCharacters(in: r.range, with: r.replacement), r.selection)
    }

    func testToggleMarker() {
        XCTAssertEqual(apply("**", "say hi now", NSRange(location: 4, length: 2)).0, "say **hi** now")
        XCTAssertEqual(apply("**", "say hi now", NSRange(location: 4, length: 2)).1, NSRange(location: 6, length: 2))
        // toggling again removes the markers around the selection
        XCTAssertEqual(apply("**", "say **hi** now", NSRange(location: 6, length: 2)).0, "say hi now")
        XCTAssertEqual(apply("**", "say **hi** now", NSRange(location: 6, length: 2)).1, NSRange(location: 4, length: 2))
        // ... or included in it
        XCTAssertEqual(apply("_", "_hi_", NSRange(location: 0, length: 4)).0, "hi")
        // no selection: caret between the markers
        let empty = apply("_", "ab", NSRange(location: 1, length: 0))
        XCTAssertEqual(empty.0, "a__b")
        XCTAssertEqual(empty.1, NSRange(location: 2, length: 0))
    }

    func testMentionQuery() {
        XCTAssertEqual(mentionQuery(text: "hi @al", caret: 6)?.query, "al")
        XCTAssertEqual(mentionQuery(text: "hi @al", caret: 6)?.range, NSRange(location: 3, length: 3))
        XCTAssertEqual(mentionQuery(text: "@", caret: 1)?.query, "")
        XCTAssertEqual(mentionQuery(text: "(@bo", caret: 4)?.query, "bo")
        XCTAssertNil(mentionQuery(text: "mail@host", caret: 9)) // not at a word start
        XCTAssertNil(mentionQuery(text: "@al ice", caret: 7))   // whitespace ends the query
        XCTAssertNil(mentionQuery(text: "hello", caret: 5))
        XCTAssertEqual(mentionQuery(text: "😀 @x", caret: 5)?.range, NSRange(location: 3, length: 2)) // UTF-16
    }

    func testSuggestionsAndResolve() {
        let members = [MentionCandidate(name: "Ann", id: "u-1"), MentionCandidate(name: "Ann Lee", id: "u-2"),
                       MentionCandidate(name: "Bob", id: "u-3")]
        XCTAssertEqual(mentionSuggestions("an", members).map(\.id), ["u-1", "u-2"])
        XCTAssertEqual(mentionSuggestions("lee", members).map(\.id), ["u-2"])
        XCTAssertEqual(mentionSuggestions("", members).count, 3)

        let text = "@Ann Lee and @Ann, not @Bobby or x@Bob; @Bob"
        let ms = resolveMentions(text: text, candidates: members)
        XCTAssertEqual(ms, [MentionRange(start: 0, length: 8, uuid: "u-2"), MentionRange(start: 13, length: 4, uuid: "u-1"),
                            MentionRange(start: 40, length: 4, uuid: "u-3")])
    }
}

final class ScrollFollowTests: XCTestCase {
    private let a = LastMessageMark(ts: 1, authorKey: "u-1", outgoing: false)
    private let b = LastMessageMark(ts: 2, authorKey: "u-1", outgoing: false)
    private let c = LastMessageMark(ts: 3, authorKey: "u-1", outgoing: false)

    func testFollowsOnlyNearBottom() {
        var f = ScrollFollow()
        XCTAssertEqual(f.lastMessageChanged(from: a, to: b), .scrollToBottom)
        XCTAssertTrue(f.scrolled(nearBottom: false))
        XCTAssertEqual(f.lastMessageChanged(from: b, to: c), .countNew)
        XCTAssertEqual(f.lastMessageChanged(from: c, to: LastMessageMark(ts: 4, authorKey: "u-2", outgoing: false)), .countNew)
        XCTAssertEqual(f.unseen, 2)
        XCTAssertEqual(f.lastMessageChanged(from: c, to: c), .none)
        XCTAssertEqual(f.lastMessageChanged(from: c, to: b), .none) // the last message was deleted
        XCTAssertEqual(f.unseen, 2)
        // own message: always shown
        XCTAssertEqual(f.lastMessageChanged(from: c, to: LastMessageMark(ts: 9, authorKey: "me", outgoing: true)), .scrollToBottom)
        XCTAssertEqual(f.unseen, 0)
        _ = f.lastMessageChanged(from: a, to: c)
        XCTAssertTrue(f.scrolled(nearBottom: true))
        XCTAssertEqual(f.unseen, 0)
        XCTAssertFalse(f.scrolled(nearBottom: true))
    }

    func testNearBottom() {
        XCTAssertTrue(ScrollFollow.isNearBottom(contentHeight: 1000, visibleMaxY: 1000))
        XCTAssertTrue(ScrollFollow.isNearBottom(contentHeight: 1000, visibleMaxY: 900))
        XCTAssertFalse(ScrollFollow.isNearBottom(contentHeight: 1000, visibleMaxY: 700))
        XCTAssertTrue(ScrollFollow.isNearBottom(contentHeight: 100, visibleMaxY: 400)) // content shorter than the view
    }

    func testUnreadDivider() {
        func m(_ out: Bool) -> Message { var x = Message(); x.outgoing = out; return x }
        let msgs = [m(false), m(true), m(false), m(true), m(false)]
        XCTAssertNil(unreadDividerIndex(msgs, unread: 0))
        XCTAssertEqual(unreadDividerIndex(msgs, unread: 1), 4)
        XCTAssertEqual(unreadDividerIndex(msgs, unread: 2), 2) // outgoing messages are not unread
        XCTAssertEqual(unreadDividerIndex(msgs, unread: 99), 0)
        XCTAssertNil(unreadDividerIndex([m(true)], unread: 1))
        XCTAssertNil(unreadDividerIndex([], unread: 3))
    }
}
