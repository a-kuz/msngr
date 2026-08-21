import XCTest
import GRDB
@testable import MsngrCore

/// A hundred pushes handed over at once after a long offline: the banners have
/// to end up in the notification centre in the order the messages were sent,
/// one banner per message, and nothing already seen or already read may appear
/// again.
final class NotificationBurstTests: XCTestCase {
    private func item(_ chatId: String, _ seq: Int, sentAt: Double? = nil) -> BurstItem {
        BurstItem(chatId: chatId, seq: seq,
                  sentAt: sentAt ?? Double(seq))
    }

    // MARK: - Order

    /// Pushes that arrive in order keep it.
    func testInOrderArrivalKeepsOrder() {
        let items = (1...5).map { item("c1", $0) }
        let plan = NotificationBurstPlanner.plan(items: items)
        XCTAssertEqual(plan.shown.map(\.seq), [1, 2, 3, 4, 5])
        XCTAssertTrue(plan.steps.allSatisfy { $0.outcome == .show })
    }

    /// Pushes shuffled by APNs are posted by seq.
    func testShuffledArrivalIsSortedBySeq() {
        let items = [4, 1, 5, 3, 2].map { item("c1", $0) }
        let plan = NotificationBurstPlanner.plan(items: items)
        XCTAssertEqual(plan.shown.map(\.seq), [1, 2, 3, 4, 5])
        // every push is answered, and each answer belongs to its own handler
        XCTAssertEqual(plan.steps.map(\.index).sorted(), [0, 1, 2, 3, 4])
        for step in plan.steps { XCTAssertEqual(step.item, items[step.index]) }
    }

    /// Inside a chat the order is the seq; the chat whose newest message is the
    /// newest of the burst is posted last, so it sits on top of the centre.
    func testChatsAreOrderedByTheirNewestMessage() {
        let items = [
            item("older", 7, sentAt: 100),
            item("newer", 2, sentAt: 300),
            item("older", 8, sentAt: 200),
            item("newer", 1, sentAt: 250),
        ]
        let plan = NotificationBurstPlanner.plan(items: items)
        XCTAssertEqual(plan.shown.map { "\($0.chatId)#\($0.seq)" },
                       ["older#7", "older#8", "newer#1", "newer#2"])
    }

    // MARK: - One message, one banner

    /// The same message pushed twice inside one window gives one banner.
    func testDuplicateInsideWindowIsShownOnce() {
        let items = [item("c1", 1), item("c1", 2), item("c1", 1)]
        let plan = NotificationBurstPlanner.plan(items: items)
        XCTAssertEqual(plan.shown.map(\.seq), [1, 2])
        XCTAssertEqual(plan.steps.filter { $0.outcome == .skip(.duplicate) }.count, 1)
    }

    /// A push for a message whose banner is already on screen is answered with
    /// nothing: reposting it would ring again for what the user has seen.
    func testAlreadyShownMessageIsSkipped() {
        let items = [item("c1", 1), item("c1", 2)]
        let plan = NotificationBurstPlanner.plan(
            items: items, state: ["c1/1": BurstItemState(alreadyShown: true)])
        XCTAssertEqual(plan.shown.map(\.seq), [2])
        XCTAssertEqual(plan.steps.first { $0.item.seq == 1 }?.outcome, .skip(.duplicate))
    }

    /// Read on another device before the window closed: no banner.
    func testMessageReadElsewhereIsSkipped() {
        let items = (1...3).map { item("c1", $0) }
        let plan = NotificationBurstPlanner.plan(
            items: items,
            state: ["c1/1": BurstItemState(read: true), "c1/2": BurstItemState(read: true)])
        XCTAssertEqual(plan.shown.map(\.seq), [3])
        XCTAssertEqual(plan.steps.first { $0.item.seq == 2 }?.outcome, .skip(.read))
    }

    func testMutedChatIsSkipped() {
        let plan = NotificationBurstPlanner.plan(
            items: [item("c1", 1)], state: ["c1/1": BurstItemState(muted: true)])
        XCTAssertTrue(plan.shown.isEmpty)
        XCTAssertEqual(plan.steps.first?.outcome, .skip(.muted))
    }

    // MARK: - Holes

    /// The burst names seqs the device never received: the hole is reported so
    /// the app can fetch it.
    func testHoleBetweenPushesIsReported() {
        let items = [item("c1", 10), item("c1", 11), item("c1", 15)]
        let plan = NotificationBurstPlanner.plan(
            items: items, baseline: ["c1": ChatBurstBaseline(lastSeq: 9)])
        XCTAssertEqual(plan.gaps.map(\.chatId), ["c1"])
        XCTAssertEqual(plan.gaps.first?.ranges, [12...14])
    }

    /// A seq the device already stores is not a hole.
    func testStoredSeqIsNotAHole() {
        let items = [item("c1", 10), item("c1", 12)]
        let plan = NotificationBurstPlanner.plan(
            items: items,
            baseline: ["c1": ChatBurstBaseline(lastSeq: 9, knownSeqs: [11])])
        XCTAssertTrue(plan.gaps.isEmpty)
    }

    /// Everything between the chat the device knows and the top of the burst is
    /// a hole after a long offline.
    func testLongOfflineLeavesOneRange() {
        let plan = NotificationBurstPlanner.plan(
            items: [item("c1", 100)], baseline: ["c1": ChatBurstBaseline(lastSeq: 5)])
        XCTAssertEqual(plan.gaps.first?.ranges, [6...99])
    }
}
