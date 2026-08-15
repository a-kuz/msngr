import XCTest
@testable import Msngr

@MainActor
final class LastSeenTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testJustLeft() {
        let text = ChatViewModel.lastSeenText(now.timeIntervalSince1970 - 5, now: now)
        XCTAssertEqual(text, "был(а) только что")
    }

    /// Часы сервера впереди клиентских: разница отрицательна, «через N сек.» недопустимо.
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
}
