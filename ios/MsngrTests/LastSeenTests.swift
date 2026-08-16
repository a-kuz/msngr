import XCTest
@testable import Msngr

@MainActor
final class LastSeenTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testJustLeft() {
        let text = ChatViewModel.lastSeenText(now.timeIntervalSince1970 - 5, now: now)
        XCTAssertEqual(text, "был(а) только что")
    }

    /// The server clock runs ahead of the client one: the difference is negative and
    /// a text like "in N sec." must never come out of it.
    func testFutureTimestampIsNotFuture() {
        let text = ChatViewModel.lastSeenText(now.timeIntervalSince1970 + 30, now: now)
        XCTAssertEqual(text, "был(а) только что")
        XCTAssertFalse(text.contains("через"))
    }

    func testOlderUsesRelativeFormat() {
        let text = ChatViewModel.lastSeenText(now.timeIntervalSince1970 - 3600, now: now)
        XCTAssertTrue(text.hasPrefix("был(а) "))
        XCTAssertFalse(text.contains("только что"))
    }

    func testMembersDeclension() {
        XCTAssertEqual(ChatViewModel.membersText(1), "1 участник")
        XCTAssertEqual(ChatViewModel.membersText(2), "2 участника")
        XCTAssertEqual(ChatViewModel.membersText(5), "5 участников")
        XCTAssertEqual(ChatViewModel.membersText(11), "11 участников")
        XCTAssertEqual(ChatViewModel.membersText(21), "21 участник")
        XCTAssertEqual(ChatViewModel.membersText(112), "112 участников")
    }
}
