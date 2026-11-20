import XCTest
@testable import CorvusCore

final class AgentAccessTests: XCTestCase {
    private let me = "+15550000000", jan = "+15550000001", eva = "+15550000002", group = "g:Z3JvdXA="

    private func msg(_ ts: Int64, _ text: String, from: String, outgoing: Bool = false) -> Message {
        var m = Message()
        m.ts = ts
        m.text = text
        m.authorKey = from
        m.outgoing = outgoing
        return m
    }

    private func fixture(_ grant: AgentGrant) -> AgentQuery {
        var s = ChatState()
        s.account = me
        var a = Conversation(key: jan, title: "Karel Dvořák")
        a.msgs = [msg(1_000, "ahoj", from: jan), msg(2_000, "pivo v pátek?", from: me, outgoing: true), msg(3_000, "jasně", from: jan)]
        var b = Conversation(key: eva, title: "Eva Nováková")
        b.msgs = [msg(1_500, "tajné pivo", from: eva)]
        var g = Conversation(key: group, title: "Kavárna", isGroup: true)
        g.msgs = [msg(2_500, "kdo jde na pivo", from: eva)]
        var hidden = msg(2_600, "secret photo", from: eva)
        hidden.viewOnce = true
        g.msgs.append(hidden)
        s.convs = [jan: a, eva: b, group: g]
        var r = Roster()
        r.account = me
        r.update(contacts: [["number": jan, "name": "Karel Dvořák"], ["number": eva, "name": "Eva Nováková"]] as [Any])
        return AgentQuery(state: s, roster: r, grant: grant)
    }

    func testSelectedChatsOnly() {
        let q = fixture(AgentGrant(id: "t", name: "T", chats: [jan, group]))
        XCTAssertEqual(Set(q.listChats().map { jsonString($0["id"]) }), [jan, group])
        XCTAssertEqual(q.readChat(eva).count, 0)
        let hits = q.searchMessages("pivo")
        XCTAssertEqual(hits.map { jsonString($0["chatId"]) }, [group, jan]) // newest first, never Eva's chat
    }

    func testAllChats() {
        let q = fixture(AgentGrant(id: "t", name: "T", allChats: true))
        XCTAssertEqual(q.listChats().count, 3)
        XCTAssertEqual(q.searchMessages("pivo").count, 3)
    }

    func testResolveByNameAndPermission() {
        let q = fixture(AgentGrant(id: "t", name: "T", chats: [jan]))
        XCTAssertEqual(q.resolveChat("karel dvorak"), .allowed(jan))
        XCTAssertEqual(q.resolveChat(jan), .allowed(jan))
        XCTAssertEqual(q.resolveChat("eva"), .needsPermission(eva))
        XCTAssertEqual(q.resolveChat("kavarna"), .needsPermission(group))
        XCTAssertEqual(q.resolveChat("nobody here"), .none)
        XCTAssertEqual(AgentQuery.nameScore("eko lab", "ECO (Lab) Team"), 650)
        XCTAssertNil(AgentQuery.nameScore("xyz lab", "ECO (Lab) Team"))
        XCTAssertGreaterThanOrEqual(AgentQuery.nameScore("eva novakova", "Eva Nováková") ?? 0, 600)
        XCTAssertEqual(q.resolveChat("eva novakova"), .needsPermission(eva))
    }

    func testSameNameTwicePicksLatest() {
        var q = fixture(AgentGrant(id: "t", name: "T", allChats: true))
        var dup = Conversation(key: "0d3c0f1e-1111-4a2b-9c3d-000000000001", title: "Karel Dvořák")
        dup.msgs = [msg(500, "old", from: "0d3c0f1e-1111-4a2b-9c3d-000000000001")]
        q.state.convs[dup.key] = dup
        XCTAssertEqual(q.resolveChat("karel dvorak"), .allowed(jan))
    }

    func testReadChatPagingAndViewOnce() {
        let q = fixture(AgentGrant(id: "t", name: "T", allChats: true))
        let all = q.readChat(jan)
        XCTAssertEqual(jsonArray(all["messageList"]).map { jsonString(jsonObject($0)["text"]) }, ["ahoj", "pivo v pátek?", "jasně"])
        XCTAssertEqual(jsonArray(all["messageList"]).map { jsonString(jsonObject($0)["from"]) }, ["Karel Dvořák", "You", "Karel Dvořák"])
        let older = q.readChat(jan, limit: 1, before: 3_000)
        XCTAssertEqual(jsonArray(older["messageList"]).map { jsonString(jsonObject($0)["text"]) }, ["pivo v pátek?"])
        XCTAssertEqual(older["hasOlder"] as? Bool, true)
        let newer = q.readChat(jan, limit: 1, after: 1_000)
        XCTAssertEqual(jsonArray(newer["messageList"]).map { jsonString(jsonObject($0)["text"]) }, ["pivo v pátek?"])
        let g = q.readChat(group)
        XCTAssertEqual(jsonArray(g["messageList"]).count, 1) // incoming view-once is never handed out
    }

    func testContacts() throws {
        let q = fixture(AgentGrant(id: "t", name: "T", chats: [jan]))
        let found = try q.searchContacts("dvorak")
        XCTAssertEqual(found.map { jsonString($0["name"]) }, ["Karel Dvořák"])
        XCTAssertEqual(jsonString(found.first?["chatId"]), jan)
        XCTAssertNil(try q.searchContacts("eva").first?["chatId"]) // exists, but its chat is not shared
        let noContacts = fixture(AgentGrant(id: "t", name: "T", chats: [jan], contacts: false))
        XCTAssertThrowsError(try noContacts.searchContacts("jan"))
    }

    func testSettingsRoundTrip() {
        let d = UserDefaults(suiteName: "agent-access-test")!
        d.removePersistentDomain(forName: "agent-access-test")
        var s = AgentAccessSettings(enabled: true)
        s.upsert(AgentGrant(id: "TEAM:id", name: "Claude Code", signer: "TEAM", chats: [jan]))
        s.save(d)
        XCTAssertEqual(AgentAccessSettings.load(d), s)
        XCTAssertEqual(AgentQuery.parseTime("2026-11-20"), AgentQuery.parseTime(AgentQuery.iso(AgentQuery.parseTime("2026-11-20")!)))
        XCTAssertEqual(AgentQuery.parseTime(1_700_000_000), 1_700_000_000_000)
    }
}
