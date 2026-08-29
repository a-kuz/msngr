import XCTest
@testable import Msngr
import MsngrCore

/// The ↑/↓ walk over the feed from the hardware keyboard, at the unit level
/// for the same reason KeyboardComposerTests is: the simulator's keyboard
/// pipe drifts under XCUITest, and a typeKey Return into the focused
/// composer lands as a newline on a drifted pipe.
@MainActor
final class FeedKeyWalkTests: XCTestCase {
    private func msg(_ seq: Int) -> Message {
        var m = Message(id: "m\(seq)", chatId: "c", fromUserId: "peer",
                        sentAt: 1_700_000_000 + Double(seq), kind: .text, text: "m\(seq)",
                        status: .sent, isOutgoing: false)
        m.seq = seq
        return m
    }

    private func controller(_ seqs: [Int]) -> MessagesViewController {
        let vc = MessagesViewController()
        vc.loadViewIfNeeded()
        // inverted feed: the newest message first, with a separator to step over
        var items: [ChatFeedItem] = seqs.sorted(by: >).map {
            .message(msg($0), tightGap: false, showTail: true, showName: false, authorName: nil)
        }
        items.append(.dateSeparator(id: "d1", label: "today"))
        vc.apply(items)
        return vc
    }

    /// ↑ enters the walk at the newest message and steps toward history.
    func testUpWalksFromNewestToOlder() {
        let vc = controller([1, 2, 3])
        XCTAssertTrue(vc.moveKeyWalk(up: true))
        XCTAssertEqual(vc.keyWalkMessage?.seq, 3)
        XCTAssertTrue(vc.moveKeyWalk(up: true))
        XCTAssertEqual(vc.keyWalkMessage?.seq, 2)
    }

    /// ↓ steps back toward the newest, and one more ↓ ends the walk.
    func testDownWalksBackAndOffTheBottom() {
        let vc = controller([1, 2])
        vc.moveKeyWalk(up: true)
        vc.moveKeyWalk(up: true)
        XCTAssertEqual(vc.keyWalkMessage?.seq, 1)
        XCTAssertTrue(vc.moveKeyWalk(up: false))
        XCTAssertEqual(vc.keyWalkMessage?.seq, 2)
        XCTAssertTrue(vc.moveKeyWalk(up: false))
        XCTAssertNil(vc.keyWalkMessage, "walking down past the newest must end the walk")
    }

    /// ↑ at the oldest message stays there instead of leaving the feed.
    func testUpStopsAtTheOldest() {
        let vc = controller([7])
        vc.moveKeyWalk(up: true)
        XCTAssertTrue(vc.moveKeyWalk(up: true))
        XCTAssertEqual(vc.keyWalkMessage?.seq, 7)
    }

    /// ↓ with no walk active is left unconsumed, and an empty feed takes no walk.
    func testNothingToWalk() {
        let vc = controller([1])
        XCTAssertFalse(vc.moveKeyWalk(up: false))
        let empty = MessagesViewController()
        empty.loadViewIfNeeded()
        XCTAssertFalse(empty.moveKeyWalk(up: true))
    }

    /// Esc clears the walk and says whether there was one to clear.
    func testClearReportsActivity() {
        let vc = controller([1])
        XCTAssertFalse(vc.clearKeyWalk())
        vc.moveKeyWalk(up: true)
        XCTAssertTrue(vc.clearKeyWalk())
        XCTAssertNil(vc.keyWalkMessage)
    }
}
