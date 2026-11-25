import XCTest
@testable import CorvusCore

final class ChatMergeTests: XCTestCase {
    private let me = "+15550000000", number = "+15550000001"
    private let uuid = "00000000-0000-4000-8000-000000000001"

    private func msg(_ ts: Int64, from: String, outgoing: Bool = false, order: Int64 = 0) -> Message {
        var m = Message()
        m.ts = ts
        m.orderTs = order
        m.text = "m\(ts)"
        m.authorKey = from
        m.outgoing = outgoing
        return m
    }

    private func state() -> ChatState {
        var s = ChatState()
        s.account = me
        var a = Conversation(key: number, title: "Karel Dvořák")
        a.msgs = [msg(1_000, from: number), msg(3_000, from: me, outgoing: true)]
        a.unread = 1
        var b = Conversation(key: uuid, title: uuid)
        var q = msg(2_000, from: uuid)
        q.reactions = [uuid: "👍", me: "❤️"]
        b.msgs = [q, msg(3_000, from: me, outgoing: true), msg(4_000, from: uuid)]
        b.unread = 2
        b.pinned = true
        b.folders = ["work"]
        s.convs = [number: a, uuid: b]
        return s
    }

    func testNothingToMergeWithoutAlias() {
        var s = state()
        XCTAssertFalse(s.hasAliasedChats())
        XCTAssertTrue(s.mergeAliasedChats().isEmpty)
        XCTAssertEqual(s.convs.count, 2)
    }

    func testUuidChatJoinsNumberChat() {
        var s = state()
        s.alias[uuid] = number
        XCTAssertTrue(s.hasAliasedChats())
        let merged = s.mergeAliasedChats()
        XCTAssertEqual(merged.map(\.from), [uuid])
        XCTAssertNil(s.convs[uuid])
        let c = s.convs[number]!
        XCTAssertEqual(c.title, "Karel Dvořák")
        XCTAssertEqual(c.msgs.map(\.ts), [1_000, 2_000, 3_000, 4_000]) // the shared sent message once
        XCTAssertEqual(c.msgs[1].authorKey, number)
        XCTAssertEqual(c.msgs[1].reactions, [number: "👍", me: "❤️"])
        XCTAssertEqual(c.unread, 3)
        XCTAssertTrue(c.pinned)
        XCTAssertEqual(c.folders, ["work"])
        XCTAssertFalse(s.hasAliasedChats())
    }

    func testUuidChatBecomesNumberChatWhenAlone() {
        var s = state()
        s.convs.removeValue(forKey: number)
        s.alias[uuid] = number
        s.contactNames[number] = "Karel Dvořák"
        _ = s.mergeAliasedChats()
        XCTAssertEqual(Array(s.convs.keys), [number])
        XCTAssertEqual(s.convs[number]!.key, number)
        XCTAssertEqual(s.convs[number]!.title, "Karel Dvořák")
        XCTAssertEqual(s.convs[number]!.msgs.count, 3)
    }

    func testMergedChatSurvivesHistoryRoundTrip() {
        var s = state()
        s.alias[uuid] = number
        _ = s.mergeAliasedChats()
        var r = ChatState()
        r.account = me
        r.loadHistory(s.allRecords())
        XCTAssertEqual(Set(r.convs.keys), [number])
        XCTAssertEqual(r.convs[number]!.msgs.map(\.ts), [1_000, 2_000, 3_000, 4_000])
        XCTAssertTrue(r.convs[number]!.pinned)
    }

    func testAgentGrantFollowsChat() {
        var a = AgentAccessSettings(enabled: true, grants: [AgentGrant(id: "a", name: "A", chats: [uuid, number, "g:x"])])
        a.rekeyChat(uuid, to: number)
        XCTAssertEqual(a.grants[0].chats, [number, "g:x"])
    }
}
