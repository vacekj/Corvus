import XCTest
@testable import CorvusCore

final class UnreadTotalTests: XCTestCase {
    func testMutedChatsDoNotCount() {
        var s = ChatState()
        s.ensure("+15550000001")
        s.ensure("+15550000002")
        s.ensure("g:R1JPVVA=", title: "Group", group: true)
        s.convs["+15550000001"]!.unread = 2
        s.convs["+15550000002"]!.unread = 3
        s.convs["g:R1JPVVA="]!.unread = 40
        XCTAssertEqual(s.unreadTotal(now: 1_000), 45)

        _ = s.setMute("g:R1JPVVA=", until: 0) // for good
        XCTAssertEqual(s.unreadTotal(now: 1_000), 5)

        _ = s.setMute("+15550000002", until: 2_000) // until a time
        XCTAssertEqual(s.unreadTotal(now: 1_000), 2)
        XCTAssertEqual(s.unreadTotal(now: 2_000), 5, "a mute that ran out counts again")

        _ = s.setMute("g:R1JPVVA=", until: nil)
        XCTAssertEqual(s.unreadTotal(now: 2_000), 45)
    }
}
