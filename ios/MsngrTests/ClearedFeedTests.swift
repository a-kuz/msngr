import XCTest
@testable import Msngr
import MsngrCore

/// The feed of a chat whose history was cleared while the screen was open.
final class ClearedFeedTests: XCTestCase {
    private func msg(_ seq: Int) -> Message {
        var m = Message(id: "m\(seq)", chatId: "c", fromUserId: "peer",
                        sentAt: 1_700_000_000 + Double(seq), kind: .text, text: "m\(seq)",
                        status: .sent, isOutgoing: false)
        m.seq = seq
        return m
    }

    @MainActor
    private func loadedController() -> MessagesViewController {
        let vc = MessagesViewController()
        vc.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        vc.loadViewIfNeeded()
        vc.view.layoutIfNeeded()
        return vc
    }

    /// An empty snapshot takes everything off the screen: no old cell is left, and no
    /// animation from an insertion that was running at that moment stays hanging.
    @MainActor
    func testClearedChatLeavesNothingOnScreen() {
        let vc = loadedController()
        vc.apply(ChatViewModel.buildFeed([msg(3), msg(2), msg(1)], members: []))
        vc.view.layoutIfNeeded()
        XCTAssertGreaterThan(vc.collectionView.numberOfItems(inSection: 0), 0)

        // a message arrives and the clear follows immediately: the feed update catches
        // the animation mid-flight
        vc.apply(ChatViewModel.buildFeed([msg(4), msg(3), msg(2), msg(1)], members: []))
        vc.apply([])
        vc.view.layoutIfNeeded()

        XCTAssertEqual(vc.collectionView.numberOfItems(inSection: 0), 0)
        XCTAssertTrue(vc.collectionView.visibleCells.isEmpty)
    }

    /// A cleared chat fills up again: the first snapshot after the clear lands the way
    /// opening the chat from scratch would.
    @MainActor
    func testChatRefillsAfterClearing() {
        let vc = loadedController()
        vc.apply(ChatViewModel.buildFeed([msg(2), msg(1)], members: []))
        vc.apply([])
        vc.apply(ChatViewModel.buildFeed([msg(5)], members: []))
        vc.view.layoutIfNeeded()

        XCTAssertEqual(vc.collectionView.numberOfItems(inSection: 0), 2) // message + date
    }

    /// A cleared chat builds no feed at all: with no messages there are no
    /// placeholders for unreadable seqs.
    @MainActor
    func testEmptyChatBuildsNoFeedItems() {
        let feed = ChatViewModel.buildFeed([], members: [], unreadableSeqs: [4, 5])
        XCTAssertTrue(feed.isEmpty)
    }
}
