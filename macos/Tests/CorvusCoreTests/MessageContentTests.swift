import XCTest
@testable import CorvusCore

final class MessageContentTests: XCTestCase {
    private func envelope(_ dm: JSON, ts: Int64 = 1_700_000_000_000) -> JSON {
        ["sourceNumber": "+15550000001", "sourceName": "Alice", "timestamp": ts, "dataMessage": dm]
    }

    // MARK: Contacts, payments

    func testSharedContactIsParsedWithFallbackText() {
        let contact: JSON = [
            "name": ["given": "Jane", "family": "Doe"],
            "phone": [["value": "+1 (555) 010-0002", "type": "MOBILE"]],
            "email": [["value": "jane@example.com", "type": "CUSTOM", "label": "Club"]],
            "address": [["street": "1 Main St", "city": "Springfield", "country": "US"]],
            "organization": "Example Inc",
            "avatar": ["attachment": ["id": "abc123", "contentType": "image/jpeg"], "isProfile": false],
        ]
        let pe = parseEnvelope(envelope(["timestamp": 5, "contacts": [contact]]))
        XCTAssertEqual(pe.kind, .message)
        let c = try! XCTUnwrap(pe.msg.sharedContacts.first)
        XCTAssertEqual(c.displayName, "Jane Doe")
        XCTAssertEqual(c.phones.first?.typeLabel, "Mobile")
        XCTAssertEqual(c.emails.first?.typeLabel, "Club")
        XCTAssertEqual(c.addresses, ["1 Main St, Springfield, US"])
        XCTAssertEqual(c.avatarId, "abc123")
        XCTAssertEqual(c.signalNumber, "+15550100002")
        XCTAssertEqual(pe.msg.text, "👤 Jane Doe")
        XCTAssertTrue(pe.msg.textIsFallback)
    }

    func testContactNumbers() {
        var c = SharedContact()
        c.phones = [.init(value: "777 123 456")]
        XCTAssertNil(c.signalNumber) // no country code: unknown
        c.phones.append(.init(value: "00420 777 123 456"))
        XCTAssertEqual(c.signalNumber, "+420777123456")
    }

    func testPaymentIsParsed() {
        let pe = parseEnvelope(envelope(["timestamp": 7, "payment": ["note": "Lunch", "receipt": "AAEC"]]))
        XCTAssertEqual(pe.kind, .message)
        XCTAssertEqual(pe.msg.payment, PaymentNote(note: "Lunch"))
        XCTAssertEqual(pe.msg.text, "💸 Payment: Lunch")
    }

    func testContentSurvivesHistoryRoundTrip() {
        var m = Message()
        m.ts = 10
        m.authorKey = "+15550000001"
        var c = SharedContact()
        c.given = "Jane"
        c.phones = [.init(value: "+15550100002", type: "MOBILE")]
        c.addresses = ["1 Main St"]
        c.avatarId = "abc"
        m.sharedContacts = [c]
        m.payment = PaymentNote(note: "x")
        m.notice = .timer(3600)
        let back = Records.messageFromRecord(Records.message("k", m))
        XCTAssertEqual(back.sharedContacts, [c])
        XCTAssertEqual(back.payment, PaymentNote(note: "x"))
        XCTAssertEqual(back.notice, .timer(3600))
        XCTAssertTrue(back.isNotice)

        m.markDeleted()
        let deleted = Records.messageFromRecord(Records.message("k", m))
        XCTAssertTrue(deleted.sharedContacts.isEmpty)
        XCTAssertNil(deleted.payment)
    }

    // MARK: Disappearing messages

    func testExpirationUpdateCarriesTimestamp() {
        let pe = parseEnvelope(envelope(["timestamp": 42, "expiresInSeconds": 604_800, "isExpirationUpdate": true]))
        XCTAssertEqual(pe.kind, .expirationUpdate)
        XCTAssertEqual(pe.expirationSeconds, 604_800)
        XCTAssertEqual(pe.msg.ts, 42)
    }

    func testGroupUpdateWithoutContentIsATimerUpdate() {
        let group: JSON = ["groupId": "Z3JvdXA=", "type": "UPDATE", "revision": 3]
        let pe = parseEnvelope(envelope(["timestamp": 50, "expiresInSeconds": 3600, "groupInfo": group]))
        XCTAssertEqual(pe.kind, .expirationUpdate)
        XCTAssertEqual(pe.groupId, "Z3JvdXA=")
        // A normal group message is not.
        let msg = parseEnvelope(envelope(["timestamp": 51, "expiresInSeconds": 3600, "message": "hi",
                                          "groupInfo": ["groupId": "Z3JvdXA=", "type": "DELIVER"] as JSON]))
        XCTAssertEqual(msg.kind, .message)
        let update = parseEnvelope(envelope(["timestamp": 52, "expiresInSeconds": 3600, "message": "hi", "groupInfo": group]))
        XCTAssertEqual(update.kind, .message)
        let noTimer = parseEnvelope(envelope(["timestamp": 53, "expiresInSeconds": 0, "groupInfo": group]))
        XCTAssertEqual(noTimer.kind, .none)
    }

    func testTimerWording() {
        XCTAssertEqual(DisappearingTimer.label(30), "30 seconds")
        XCTAssertEqual(DisappearingTimer.label(60), "1 minute")
        XCTAssertEqual(DisappearingTimer.label(6 * 3600), "6 hours")
        XCTAssertEqual(DisappearingTimer.label(86_400), "1 day")
        XCTAssertEqual(DisappearingTimer.label(604_800), "1 week")
        XCTAssertEqual(DisappearingTimer.label(28 * 86_400), "4 weeks")
        XCTAssertEqual(DisappearingTimer.label(90), "90 seconds")
        XCTAssertEqual(DisappearingTimer.noticeText(604_800, actor: nil), "You set the disappearing message timer to 1 week.")
        XCTAssertEqual(DisappearingTimer.noticeText(300, actor: "Alice"), "Alice set the disappearing message timer to 5 minutes.")
        XCTAssertEqual(DisappearingTimer.noticeText(0, actor: "Alice"), "Alice disabled disappearing messages.")
        XCTAssertEqual(DisappearingTimer.noticeText(0, actor: nil), "You disabled disappearing messages.")
    }

    func testCountdownSteps() {
        let full = DisappearingTimer.steps
        XCTAssertEqual(DisappearingTimer.step(expiresInSeconds: 60, startMs: 0, now: 999), full) // not started
        XCTAssertEqual(DisappearingTimer.step(expiresInSeconds: 60, startMs: 1000, now: 1000), full)
        XCTAssertEqual(DisappearingTimer.step(expiresInSeconds: 60, startMs: 1000, now: 31_000), full / 2)
        XCTAssertEqual(DisappearingTimer.step(expiresInSeconds: 60, startMs: 1000, now: 60_999), 1) // a sliver until the end
        XCTAssertEqual(DisappearingTimer.step(expiresInSeconds: 60, startMs: 1000, now: 61_000), 0)
        XCTAssertEqual(DisappearingTimer.step(expiresInSeconds: 60, startMs: 1000, now: 999_000), 0)
        // The shared clock: once a second for short timers, at most once a minute.
        XCTAssertEqual(DisappearingTimer.tickInterval(shortestSeconds: 30), 1.25)
        XCTAssertEqual(DisappearingTimer.tickInterval(shortestSeconds: 5), 1)
        XCTAssertEqual(DisappearingTimer.tickInterval(shortestSeconds: 604_800), 60)
    }

    func testNoticesAreNotSearched() {
        var n = Message()
        n.ts = 1
        n.authorKey = "me"
        n.notice = .timer(60)
        n.text = DisappearingTimer.noticeText(60, actor: nil)
        var m = Message()
        m.ts = 2
        m.authorKey = "u"
        m.text = "the timer is set"
        XCTAssertEqual(ChatSearch.matches([n, m], "timer"), [m.id])
        var c = Conversation(key: "u", title: "U")
        c.msgs = [n, m]
        XCTAssertEqual(searchMessages(["u": c], query: "timer").map(\.ts), [2])
    }

    // MARK: Long messages

    func testLongTextMerge() {
        let full = String(repeating: "a", count: 2000) + " and the rest"
        let shown = String(repeating: "a", count: 2000)
        XCTAssertEqual(LongText.merge(displayed: shown, mentions: [], full: full), full)
        // Mentions: the body shows "@Bob" where the original had one placeholder.
        let raw = "Hi \u{FFFC}, " + String(repeating: "b", count: 10) + "TAIL"
        let displayed = "Hi @Bob, " + String(repeating: "b", count: 10)
        let merged = LongText.merge(displayed: displayed, mentions: [MentionRange(start: 3, length: 4, uuid: "u")], full: raw)
        XCTAssertEqual(merged, displayed + "TAIL")
    }

    func testLongTextCut() {
        XCTAssertNil(LongText.cut(String(repeating: "x", count: 900), limit: LongText.initialLength))
        let words = Array(repeating: "word", count: 400).joined(separator: " ") // 1999 characters
        let cut = try! XCTUnwrap(LongText.cut(words, limit: LongText.initialLength))
        let n = words.distance(from: words.startIndex, to: cut)
        XCTAssertLessThanOrEqual(n, LongText.initialLength)
        XCTAssertGreaterThan(n, LongText.initialLength * 4 / 5)
        XCTAssertEqual(words[cut], " ") // at a word boundary
        XCTAssertNil(LongText.cut(words, limit: 5000))
    }

    func testApplyLongTextReplacesBodyAndDropsAttachment() {
        var state = ChatState()
        var m = Message()
        m.ts = 100
        m.authorKey = "u"
        m.text = "short"
        var a = Attachment()
        a.id = "lt"
        a.contentType = Attachment.longTextType
        m.attachments = [a]
        XCTAssertEqual(m.longTextAttachmentIndex, 0)
        _ = state.addMessage("u", m)
        let rec = try! XCTUnwrap(state.applyLongText("u", ts: 100, author: "u", full: "short and long"))
        XCTAssertEqual(state.convs["u"]!.msgs[0].text, "short and long")
        XCTAssertTrue(state.convs["u"]!.msgs[0].attachments.isEmpty)
        XCTAssertFalse(state.convs["u"]!.msgs[0].isEdited)
        XCTAssertNil(state.applyLongText("u", ts: 100, author: "u", full: "again")) // done once
        // Replaying the history gives the same message.
        var replay = ChatState()
        replay.loadHistory([Records.message("u", m), rec])
        XCTAssertEqual(replay.convs["u"]!.msgs[0].text, "short and long")
        XCTAssertTrue(replay.convs["u"]!.msgs[0].attachments.isEmpty)
    }

    // MARK: Locations

    func testLocationShare() {
        let text = "Café Example\nMain Square 1, Prague\nhttps://maps.google.com/maps?q=50.087%2C14.421"
        let loc = try! XCTUnwrap(LocationShare.parse(text))
        XCTAssertEqual(loc.latitude, 50.087, accuracy: 1e-9)
        XCTAssertEqual(loc.longitude, 14.421, accuracy: 1e-9)
        XCTAssertEqual(loc.title, "Café Example")
        XCTAssertEqual(loc.address, "Main Square 1, Prague")
        XCTAssertNotNil(loc.mapsURL)
        XCTAssertNotNil(LocationShare.parse("https://maps.google.com/maps?q=-33.8,151.2"))
        XCTAssertNil(LocationShare.parse("look at https://maps.google.com/maps?q=50.0%2C14.0 later"))
        XCTAssertNil(LocationShare.parse("https://maps.google.com/maps?q=pizza"))
        XCTAssertNil(LocationShare.parse("hello"))
    }

    // MARK: Search highlighting

    func testHighlightRanges() {
        let text = "Lunch? lunch! LUNCH"
        XCTAssertEqual(SearchHighlight.ranges(of: "lunch", in: text).map { String(text[$0]) }, ["Lunch", "lunch", "LUNCH"])
        XCTAssertEqual(SearchHighlight.ranges(of: "  ", in: text), [])
        XCTAssertEqual(SearchHighlight.nsRanges(of: "kun", in: "Příliš kůň", options: SearchHighlight.listOptions, locale: nil),
                       [NSRange(location: 7, length: 3)])
        XCTAssertEqual(SearchHighlight.nsRanges(of: "kun", in: "Příliš kůň"), []) // the chat search keeps accents
    }

    func testMessageHitCarriesHighlights() {
        var c = Conversation(key: "u", title: "U")
        var m = Message()
        m.ts = 3
        m.authorKey = "u"
        m.text = "Meet at the café, the CAFE has wifi"
        c.msgs = [m]
        let hit = try! XCTUnwrap(searchMessages(["u": c], query: "cafe").first)
        let ns = hit.snippet as NSString
        XCTAssertEqual(hit.highlights.map { ns.substring(with: $0) }, ["café", "CAFE"])
    }

    // MARK: Emoji

    private let index = EmojiShortcodeIndex(names: [
        ("😀", "grinning face"), ("😄", "smiling face with open mouth and smiling eyes"), ("😂", "face with tears of joy"),
        ("🙂", "slightly smiling face"), ("👍", "thumbs up sign"), ("😼", "cat face with wry smile"),
    ])

    func testShortcodeSearch() {
        XCTAssertEqual(EmojiShortcodeIndex.code(for: "face with tears of joy"), "face_with_tears_of_joy")
        XCTAssertEqual(EmojiShortcodeIndex.code(for: "Flag: Czechia"), "flag_czechia")
        let smi = index.search("smi")
        XCTAssertEqual(smi.first, .init(emoji: "😄", code: "smile")) // the well-known alias first
        XCTAssertEqual(Set(smi.map(\.emoji)).count, smi.count)    // one entry per emoji
        XCTAssertTrue(smi.contains { $0.emoji == "🙂" })           // word start in the long name
        XCTAssertEqual(index.search("joy").first?.emoji, "😂")
        XCTAssertEqual(index.search("+1").first?.emoji, "👍")
        XCTAssertEqual(index.search("tears").first?.emoji, "😂")
        XCTAssertTrue(index.search("ile").contains { $0.emoji == "😼" }) // inside a word, 3+ characters
        XCTAssertEqual(index.search("smi", limit: 2).count, 2)
        XCTAssertEqual(index.emoji(forCode: "face_with_tears_of_joy"), "😂")
        XCTAssertEqual(index.emoji(forCode: "JOY"), "😂")
        XCTAssertNil(index.emoji(forCode: "nope"))
    }

    func testShortcodeQueryDetection() {
        XCTAssertEqual(emojiShortcodeQuery(text: "hi :smi", caret: 7)?.query, "smi")
        XCTAssertEqual(emojiShortcodeQuery(text: "hi :smi", caret: 7)?.range, NSRange(location: 3, length: 4))
        XCTAssertEqual(emojiShortcodeQuery(text: ":+1", caret: 3)?.query, "+1")
        XCTAssertNil(emojiShortcodeQuery(text: "hi :s", caret: 5))          // two characters at least
        XCTAssertNil(emojiShortcodeQuery(text: "at 12:30", caret: 8))       // a time
        XCTAssertNil(emojiShortcodeQuery(text: "https://x", caret: 9))      // a URL
        XCTAssertNil(emojiShortcodeQuery(text: "hi :smi there", caret: 13)) // caret elsewhere
        XCTAssertNil(emojiShortcodeQuery(text: ":--", caret: 3))
        let done = emojiShortcodeCompleted(text: "ok :joy:", caret: 8)
        XCTAssertEqual(done?.code, "joy")
        XCTAssertEqual(done?.range, NSRange(location: 3, length: 5))
        XCTAssertNil(emojiShortcodeCompleted(text: "ok :joy", caret: 7))
        XCTAssertNil(emojiShortcodeCompleted(text: "a:joy:", caret: 6))
    }

    func testSkinTones() {
        let wave = ["👋🏻", "👋🏼", "👋🏽", "👋🏾", "👋🏿"]
        XCTAssertEqual(EmojiSkinTone.apply(0, to: "👋", variants: wave), "👋")
        XCTAssertEqual(EmojiSkinTone.apply(3, to: "👋", variants: wave), "👋🏽")
        XCTAssertEqual(EmojiSkinTone.apply(9, to: "👋", variants: wave), "👋")
        XCTAssertEqual(EmojiSkinTone.apply(2, to: "😀", variants: []), "😀")
        // Two people: both in the chosen tone.
        let handshake = ["🤝🏻", "🫱🏻\u{200D}🫲🏼", "🫱🏼\u{200D}🫲🏻", "🫱🏼\u{200D}🫲🏼"]
        XCTAssertEqual(EmojiSkinTone.apply(2, to: "🤝", variants: handshake), "🫱🏼\u{200D}🫲🏼")
    }
}
