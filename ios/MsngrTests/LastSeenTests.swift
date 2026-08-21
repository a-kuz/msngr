import XCTest
@testable import Msngr

@MainActor
final class LastSeenTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Comparisons go through the same catalog key the product reads, so the
    /// test holds in whatever language the simulator runs.
    private func s(_ key: String.LocalizationValue) -> String {
        String(localized: key)
    }

    func testJustLeft() {
        let text = ChatViewModel.lastSeenText(now.timeIntervalSince1970 - 5, now: now)
        XCTAssertEqual(text, s("last seen just now"))
    }

    /// The server clock runs ahead of the client one: the difference is negative and
    /// a text like "in N sec." must never come out of it.
    func testFutureTimestampIsNotFuture() {
        let text = ChatViewModel.lastSeenText(now.timeIntervalSince1970 + 30, now: now)
        XCTAssertEqual(text, s("last seen just now"))
    }

    func testOlderUsesRelativeFormat() {
        let text = ChatViewModel.lastSeenText(now.timeIntervalSince1970 - 3600, now: now)
        let relTime = RelativeDateTimeFormatter.short.localizedString(
            for: Date(timeIntervalSince1970: now.timeIntervalSince1970 - 3600), relativeTo: now)
        XCTAssertEqual(text, s("last seen \(relTime)"))
        XCTAssertNotEqual(text, s("last seen just now"))
    }

    func testMembersDeclension() {
        XCTAssertEqual(ChatViewModel.membersText(1), NSString(format: String(localized: "%lld participants") as NSString, 1) as String)
        XCTAssertEqual(ChatViewModel.membersText(2), NSString(format: String(localized: "%lld participants") as NSString, 2) as String)
        XCTAssertEqual(ChatViewModel.membersText(5), NSString(format: String(localized: "%lld participants") as NSString, 5) as String)
        XCTAssertEqual(ChatViewModel.membersText(11), NSString(format: String(localized: "%lld participants") as NSString, 11) as String)
        XCTAssertEqual(ChatViewModel.membersText(21), NSString(format: String(localized: "%lld participants") as NSString, 21) as String)
        XCTAssertEqual(ChatViewModel.membersText(112), NSString(format: String(localized: "%lld participants") as NSString, 112) as String)
    }
}
