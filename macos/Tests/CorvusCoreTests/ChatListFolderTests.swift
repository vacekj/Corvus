import XCTest
@testable import CorvusCore

final class MuteTimerTests: XCTestCase {
    private func state(_ keys: [String]) -> ChatState {
        var s = ChatState()
        for k in keys { s.ensure(k, title: k, group: k.hasPrefix("g:")) }
        return s
    }

    func testDurations() {
        XCTAssertEqual(MuteDuration.oneHour.until(now: 1_000), 3_601_000)
        XCTAssertEqual(MuteDuration.oneWeek.until(now: 0), 604_800_000)
        XCTAssertEqual(MuteDuration.always.until(now: 1_000), 0)
        XCTAssertEqual(MuteDuration.allCases.map(\.title), ["1 hour", "8 hours", "1 day", "1 week", "Always"])
    }

    func testSetMuteWritesOnlyRealChanges() {
        var s = state(["+1", "g:abc"])
        let r = s.setMute("+1", until: 5_000)
        XCTAssertEqual(r?["u"] as? Int64, 5_000)
        XCTAssertTrue(s.convs["+1"]!.muted)
        XCTAssertNil(s.setMute("+1", until: 5_000), "same mute again is no change")
        XCTAssertNotNil(s.setMute("+1", until: 0), "timed -> always is a change")
        XCTAssertNil(s.setMute("+1", until: 0))
        XCTAssertNotNil(s.setMute("+1", until: nil))
        XCTAssertFalse(s.convs["+1"]!.muted)
        XCTAssertNil(s.setMute("+1", until: nil))
        XCTAssertNil(s.setMute("unknown", until: 0))
    }

    func testExpiryAndNextExpiry() {
        var s = state(["a", "b", "c", "d"])
        _ = s.setMute("a", until: 1_000)
        _ = s.setMute("b", until: 3_000)
        _ = s.setMute("c", until: 0) // always
        XCTAssertEqual(s.nextMuteExpiry(), 1_000)
        XCTAssertEqual(s.expiredMutes(now: 999), [])
        XCTAssertEqual(s.expiredMutes(now: 1_000), ["a"])
        XCTAssertEqual(s.expiredMutes(now: 5_000), ["a", "b"])
        XCTAssertTrue(s.convs["a"]!.isMuted(at: 999))
        XCTAssertFalse(s.convs["a"]!.isMuted(at: 1_000))
        XCTAssertTrue(s.convs["c"]!.isMuted(at: .max))
        XCTAssertFalse(s.convs["d"]!.isMuted(at: 0))
        _ = s.setMute("a", until: nil)
        XCTAssertEqual(s.nextMuteExpiry(), 3_000)
        _ = s.setMute("b", until: nil)
        XCTAssertNil(s.nextMuteExpiry())
    }

    func testMuteRecordsRoundTrip() {
        var s = state(["+1", "+2"])
        _ = s.setMute("+1", until: 123_456)
        _ = s.setMute("+2", until: 0)
        var loaded = ChatState()
        loaded.loadHistory(s.allRecords())
        XCTAssertEqual(loaded.convs["+1"]!.muteUntilMs, 123_456)
        XCTAssertTrue(loaded.convs["+1"]!.muted)
        XCTAssertEqual(loaded.convs["+2"]!.muteUntilMs, 0)
        XCTAssertTrue(loaded.convs["+2"]!.muted)
        // An "always" record (as the Qt app writes it) carries no end; unmuting drops a stored end.
        loaded.loadHistory([Records.mute("+1", false)])
        XCTAssertFalse(loaded.convs["+1"]!.muted)
        XCTAssertEqual(loaded.convs["+1"]!.muteUntilMs, 0)
        XCTAssertNil(Records.mute("+1", true)["u"])
    }

    func testRemainingText() {
        let h: Int64 = 3_600_000
        XCTAssertEqual(MuteText.remaining(untilMs: 10_000, now: 0), "1 min")
        XCTAssertEqual(MuteText.remaining(untilMs: 45 * 60_000, now: 0), "45 min")
        XCTAssertEqual(MuteText.remaining(untilMs: h, now: 0), "1 h")
        XCTAssertEqual(MuteText.remaining(untilMs: 8 * h - 60_000, now: 0), "7 h 59 min")
        XCTAssertEqual(MuteText.remaining(untilMs: 24 * h, now: 0), "1 day")
        XCTAssertEqual(MuteText.remaining(untilMs: 7 * 24 * h - h, now: 0), "6 days 23 h")
        XCTAssertEqual(MuteText.remaining(untilMs: 0, now: 5_000), "1 min")
    }
}

final class ChatFolderTests: XCTestCase {
    private let direct = ChatFolderFacts(key: "+1", isGroup: false, unread: false, muted: false)
    private let unreadGroup = ChatFolderFacts(key: "g:a", isGroup: true, unread: true, muted: false)
    private let mutedUnread = ChatFolderFacts(key: "+2", isGroup: false, unread: true, muted: true)
    private let picked = ChatFolderFacts(key: "g:b", isGroup: true, unread: false, muted: false, folders: ["work"])

    func testPresets() {
        let all = [direct, unreadGroup, mutedUnread, picked]
        let unread = ChatFolder.Preset.unread.folder()
        XCTAssertEqual(all.filter(unread.contains).map(\.key), ["g:a", "+2"])
        XCTAssertEqual(all.filter(ChatFolder.Preset.groups.folder().contains).map(\.key), ["g:a", "g:b"])
        XCTAssertEqual(all.filter(ChatFolder.Preset.direct.folder().contains).map(\.key), ["+1", "+2"])
        XCTAssertTrue(ChatFolder.Preset.groups.matches(ChatFolder(id: "x", name: "Mine", includeGroups: true)))
        XCTAssertFalse(ChatFolder.Preset.groups.matches(ChatFolder(id: "x", name: "Mine", includeGroups: true, onlyUnread: true)))
    }

    func testCustomFolder() {
        var work = ChatFolder(id: "work", name: "Work")
        let all = [direct, unreadGroup, mutedUnread, picked]
        XCTAssertEqual(all.filter(work.contains).map(\.key), ["g:b"])
        work.includeDirect = true
        work.includeMuted = false
        XCTAssertEqual(all.filter(work.contains).map(\.key), ["+1", "g:b"])
        work.onlyUnread = true
        XCTAssertEqual(all.filter(work.contains).map(\.key), [])
    }

    func testFilterKeepsOrderAndOpenChat() {
        let all = [direct, unreadGroup, mutedUnread, picked]
        let id: (ChatFolderFacts) -> ChatFolderFacts = { $0 }
        XCTAssertEqual(ChatListFilter.apply(all, facts: id, folder: nil, unreadOnly: false).map(\.key), all.map(\.key))
        XCTAssertEqual(ChatListFilter.apply(all, facts: id, folder: nil, unreadOnly: true).map(\.key), ["g:a", "+2"])
        XCTAssertEqual(ChatListFilter.apply(all, facts: id, folder: nil, unreadOnly: true, keep: "+1").map(\.key),
                       ["+1", "g:a", "+2"])
        let groups = ChatFolder.Preset.groups.folder()
        XCTAssertEqual(ChatListFilter.apply(all, facts: id, folder: groups, unreadOnly: true).map(\.key), ["g:a"])
        XCTAssertEqual(ChatListFilter.unreadChats(all, facts: id, folder: nil), 1, "muted chats are not counted")
        XCTAssertEqual(ChatListFilter.unreadChats(all, facts: id, folder: groups), 1)
        XCTAssertEqual(ChatListFilter.unreadChats(all, facts: id, folder: ChatFolder.Preset.direct.folder()), 0)
    }

    func testFactsFromConversation() {
        var c = Conversation(key: "+1", title: "A")
        XCTAssertFalse(ChatFolderFacts(c).unread)
        c.markedUnread = true
        XCTAssertTrue(ChatFolderFacts(c).unread)
        c.markedUnread = false
        c.unread = 3
        c.folders = ["x"]
        XCTAssertEqual(ChatFolderFacts(c), ChatFolderFacts(key: "+1", isGroup: false, unread: true, muted: false, folders: ["x"]))
    }

    func testMembershipAndWallpaperRecords() {
        var s = ChatState()
        s.ensure("+1", title: "A")
        s.ensure("g:x", title: "G", group: true)
        XCTAssertNotNil(s.setFolder("+1", folder: "work", member: true))
        XCTAssertNil(s.setFolder("+1", folder: "work", member: true))
        XCTAssertNotNil(s.setFolder("g:x", folder: "work", member: true))
        XCTAssertNotNil(s.setFolder("g:x", folder: "home", member: true))
        XCTAssertNotNil(s.setWallpaper("+1", "navy"))
        XCTAssertNil(s.setWallpaper("+1", "navy"))
        var loaded = ChatState()
        loaded.loadHistory(s.allRecords())
        XCTAssertEqual(loaded.convs["+1"]!.folders, ["work"])
        XCTAssertEqual(loaded.convs["g:x"]!.folders, ["work", "home"])
        XCTAssertEqual(loaded.convs["+1"]!.wallpaper, "navy")
        let removed = loaded.removeFolder("work")
        XCTAssertEqual(removed.count, 2)
        XCTAssertEqual(loaded.convs["g:x"]!.folders, ["home"])
        loaded.loadHistory(removed)
        XCTAssertTrue(loaded.convs["+1"]!.folders.isEmpty)
    }

    func testFolderListCoding() {
        let list = [ChatFolder.Preset.unread.folder(id: "u"), ChatFolder(id: "w", name: "Work", includeGroups: true),
                    ChatFolder(id: "w", name: "Duplicate")]
        let decoded = ChatFolder.decode(ChatFolder.encode(list))
        XCTAssertEqual(decoded, Array(list.prefix(2)))
        XCTAssertEqual(ChatFolder.decode(nil), [])
        XCTAssertEqual(ChatFolder.decode(Data("nonsense".utf8)), [])
    }

    func testZoomLevels() {
        XCTAssertEqual(TextZoomLevels.larger(1.0), 1.1)
        XCTAssertEqual(TextZoomLevels.smaller(1.0), 0.9)
        XCTAssertEqual(TextZoomLevels.larger(2.0), 2.0)
        XCTAssertEqual(TextZoomLevels.smaller(0.75), 0.75)
        XCTAssertEqual(TextZoomLevels.nearest(1.3), 1.25)
        XCTAssertEqual(TextZoomLevels.larger(1.3), 1.5)
        XCTAssertEqual(TextZoomLevels.label(1.25), "125 %")
    }
}
