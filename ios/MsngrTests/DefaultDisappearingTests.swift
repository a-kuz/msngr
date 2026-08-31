import XCTest
@testable import Msngr

/// Which TTL a just-created chat gets from the Privacy default, if any.
final class DefaultDisappearingTests: XCTestCase {

    func testOffSendsNothing() {
        XCTAssertNil(DefaultDisappearingTimer.ttlForCreatedChat(settingRaw: 0, existedBefore: false))
    }

    func testEachOptionYieldsItsTTL() {
        XCTAssertEqual(DefaultDisappearingTimer.ttlForCreatedChat(settingRaw: 86_400, existedBefore: false), 86_400)
        XCTAssertEqual(DefaultDisappearingTimer.ttlForCreatedChat(settingRaw: 604_800, existedBefore: false), 604_800)
        XCTAssertEqual(DefaultDisappearingTimer.ttlForCreatedChat(settingRaw: 2_592_000, existedBefore: false), 2_592_000)
    }

    func testExistingChatIsLeftAlone() {
        XCTAssertNil(DefaultDisappearingTimer.ttlForCreatedChat(settingRaw: 86_400, existedBefore: true))
    }

    func testUnknownStoredValueSendsNothing() {
        XCTAssertNil(DefaultDisappearingTimer.ttlForCreatedChat(settingRaw: 12_345, existedBefore: false))
    }
}
