import XCTest
@testable import MsngrCore

/// Which chats the next catch-up portion asks for. A portion that runs out of
/// budget leaves chats untouched and says nothing about them; asking only the
/// ones it answered is how a quiet chat behind a flooded one stopped being
/// asked for at all, and its messages never arrived.
final class CatchupPortionTests: XCTestCase {
    func testAnUntouchedChatIsAskedForAgain() {
        let next = SyncEngine.nextPortion(asked: ["flooded", "quiet", "another"],
                                          answered: ["flooded"],
                                          pending: ["flooded"])
        XCTAssertEqual(next, ["flooded", "quiet", "another"])
    }

    func testACaughtUpChatIsLeftAlone() {
        let next = SyncEngine.nextPortion(asked: ["flooded", "quiet"],
                                          answered: ["flooded", "quiet"],
                                          pending: ["flooded"])
        XCTAssertEqual(next, ["flooded"])
    }

    func testNothingLeftAsksForNothing() {
        XCTAssertTrue(SyncEngine.nextPortion(asked: ["a", "b"],
                                             answered: ["a", "b"],
                                             pending: []).isEmpty)
    }
}
