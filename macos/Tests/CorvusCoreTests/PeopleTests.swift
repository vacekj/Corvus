import XCTest
@testable import CorvusCore

final class PeopleTests: XCTestCase {
    private let uuid1 = "0d3c0f1e-1111-4a2b-9c3d-000000000001"
    private let uuid2 = "0d3c0f1e-2222-4a2b-9c3d-000000000002"

    func testServiceIdAndPhoneNumber() {
        XCTAssertTrue(People.isServiceId(uuid1))
        XCTAssertTrue(People.isServiceId("PNI:" + uuid1))
        XCTAssertFalse(People.isServiceId("+15550000001"))
        XCTAssertFalse(People.isServiceId("name.12"))
        XCTAssertFalse(People.isServiceId("g:abc"))
        XCTAssertTrue(People.isPhoneNumber("+15550000001"))
        XCTAssertFalse(People.isPhoneNumber("15550000001"))
        XCTAssertFalse(People.isPhoneNumber("+1 555"))
        XCTAssertFalse(People.isPhoneNumber(uuid1))
    }

    func testDisplayNameNeverShowsUUID() {
        XCTAssertEqual(People.displayName(names: ["Alice"], number: "+15550000001"), "Alice")
        XCTAssertEqual(People.displayName(names: ["", uuid1, " Bob "], number: "+15550000001"), "Bob")
        XCTAssertEqual(People.displayName(names: [uuid1], number: "+15550000001"), "+15550000001")
        XCTAssertEqual(People.displayName(names: [uuid1], number: uuid1), People.unknown)
        XCTAssertEqual(People.displayName(names: []), People.unknown)
        XCTAssertEqual(People.displayName(names: [], unknown: "Someone"), "Someone")
    }

    func testDetailHidesDuplicatesAndUUIDs() {
        XCTAssertEqual(People.detail(title: "Alice", address: "+15550000001"), "+15550000001")
        XCTAssertEqual(People.detail(title: "Alice", address: "alice.42"), "alice.42")
        XCTAssertEqual(People.detail(title: "+15550000001", address: "+15550000001"), "")
        XCTAssertEqual(People.detail(title: "Alice", address: uuid1), "")
        XCTAssertEqual(People.detail(title: "Alice", address: ""), "")
    }

    func testMemberSortYouThenAdminsThenAlphabetical() {
        let me = GroupMember(number: "+15550000000")
        let names = ["+15550000000": "You", "+15550000001": "zoe", "+15550000002": "Adam", "+15550000003": "bob",
                     "+15550000004": "Carl", "+15550000005": "+15550000005", uuid1: People.unknown]
        let members = [
            GroupMember(number: "+15550000001"),
            GroupMember(uuid: uuid1),
            GroupMember(number: "+15550000005"),
            GroupMember(number: "+15550000004", isAdmin: true),
            GroupMember(number: "+15550000003"),
            me,
            GroupMember(number: "+15550000002", isAdmin: true),
        ]
        let sorted = People.sortedMembers(members, isSelf: { $0 == me }, name: { names[$0.id]! })
        XCTAssertEqual(sorted.map { names[$0.id]! }, ["You", "Adam", "Carl", "bob", "zoe", "+15550000005", People.unknown])
    }

    func testMemberSortAdminSelfStaysFirstAndOrderIsStable() {
        let me = GroupMember(number: "+15550000000", isAdmin: true)
        let a = GroupMember(uuid: uuid2)
        let b = GroupMember(uuid: uuid1)
        let sorted = People.sortedMembers([a, b, me], isSelf: { $0 == me }, name: { $0 == me ? "You" : People.unknown })
        XCTAssertEqual(sorted, [me, b, a])
    }

    func testMatches() {
        XCTAssertTrue(People.matches("", name: "Alice", detail: ""))
        XCTAssertTrue(People.matches("ali", name: "Alice", detail: ""))
        XCTAssertTrue(People.matches("al.4", name: "Alice", detail: "al.42"))
        XCTAssertTrue(People.matches("555 000", name: "Alice", detail: "", number: "+15550000001"))
        XCTAssertFalse(People.matches("55", name: "Alice", detail: "", number: "+15550000001"))
        XCTAssertFalse(People.matches("bob", name: "Alice", detail: "+15550000001"))
    }
}
