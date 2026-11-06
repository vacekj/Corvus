import XCTest
@testable import CorvusCore

final class RankingTests: XCTestCase {
    func testTiers() {
        XCTAssertEqual(PickerRanking.tier("domi", "Dominik Novák"), 2)
        XCTAssertEqual(PickerRanking.tier("nov", "Dominik Novák"), 2)
        XCTAssertEqual(PickerRanking.tier("NOVA", "Dominik Novák"), 2)  // case and diacritics ignored
        XCTAssertEqual(PickerRanking.tier("min", "Dominik Novák"), 1)
        XCTAssertEqual(PickerRanking.tier("dnk", "Dominik Novák"), 0)
        XCTAssertEqual(PickerRanking.tier("", "Anyone"), 2)
    }

    func testActivityPrefersFrequentRecentChats() {
        let now: Int64 = 1_800_000_000_000, day: Int64 = 86_400_000
        let busy = (0..<50).map { (now - Int64($0) * day / 2, true) }          // 50 sent in the last 25 days
        let old = (0..<200).map { (now - 120 * day - Int64($0) * day, true) }  // many, but months ago
        let one = [(now - day, true)]                                          // a single message yesterday
        let a = PickerRanking.activity(busy, now: now)
        XCTAssertEqual(PickerRanking.activity(old, now: now), 0)
        XCTAssertGreaterThan(a, PickerRanking.activity(one, now: now))
        XCTAssertGreaterThan(PickerRanking.activity(one, now: now), 0)
        // Own messages weigh more than received ones (a busy group that the user only reads ranks lower).
        let received = (0..<50).map { (now - Int64($0) * day / 2, false) }
        XCTAssertGreaterThan(a, PickerRanking.activity(received, now: now))
    }
}
