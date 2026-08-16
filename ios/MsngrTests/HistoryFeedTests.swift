import XCTest
@testable import Msngr
import MsngrCore

/// The feed around unreadable messages and the start of history.
final class HistoryFeedTests: XCTestCase {
    private func msg(_ seq: Int) -> Message {
        var m = Message(id: "m\(seq)", chatId: "c", fromUserId: "peer",
                        sentAt: 1_700_000_000 + Double(seq), kind: .text, text: "m\(seq)",
                        status: .sent, isOutgoing: false)
        m.msgId = "m\(seq)"
        m.seq = seq
        return m
    }

    private func unreadableIds(_ feed: [ChatFeedItem]) -> [String] {
        feed.compactMap { if case .unreadable(let id) = $0 { return id } else { return nil } }
    }

    /// An unreadable seq between two messages of the window: one placeholder where the hole is.
    @MainActor
    func testUnreadableSeqBetweenMessagesBecomesOneItem() {
        let feed = ChatViewModel.buildFeed([msg(5), msg(3)], members: [], unreadableSeqs: [4])
        XCTAssertEqual(unreadableIds(feed), ["gap:4-4"])
        // the placeholder sits between the messages: the feed is inverted, so older items
        // come later in the array
        let ids = feed.map(\.id)
        XCTAssertLessThan(ids.firstIndex(of: "m5")!, ids.firstIndex(of: "gap:4-4")!)
        XCTAssertLessThan(ids.firstIndex(of: "gap:4-4")!, ids.firstIndex(of: "m3")!)
    }

    /// Consecutive unreadable seqs collapse into a single placeholder instead of a row of them.
    @MainActor
    func testAdjacentUnreadableSeqsCollapse() {
        let feed = ChatViewModel.buildFeed([msg(10), msg(5)], members: [],
                                           unreadableSeqs: [6, 7, 8, 9])
        XCTAssertEqual(unreadableIds(feed), ["gap:6-9"])
    }

    /// A gap below the oldest message of the window is simply the not-yet-loaded bottom,
    /// and gets no placeholder.
    @MainActor
    func testGapBelowOldestLoadedMessageHasNoPlaceholder() {
        let feed = ChatViewModel.buildFeed([msg(9), msg(8)], members: [], unreadableSeqs: [3, 4])
        XCTAssertTrue(unreadableIds(feed).isEmpty)
    }

    /// Once the oldest message on the device is reached, the very top of the feed holds
    /// one item rather than a placeholder per missing message.
    @MainActor
    func testHistoryStartIsASingleItemAtTheTop() {
        let feed = ChatViewModel.buildFeed([msg(9), msg(8)], members: [], atHistoryStart: true)
        guard case .historyStart = feed.last else {
            return XCTFail("the last feed item must be the history start, got \(String(describing: feed.last))")
        }
        XCTAssertEqual(feed.filter { if case .historyStart = $0 { return true } else { return false } }.count, 1)
    }

    /// An empty feed gets no "history starts here" item.
    @MainActor
    func testEmptyFeedHasNoHistoryStart() {
        XCTAssertTrue(ChatViewModel.buildFeed([], members: [], atHistoryStart: true).isEmpty)
    }

    /// The unread marker and the placeholders coexist: item ids stay unique.
    @MainActor
    func testFeedIdsStayUnique() {
        let feed = ChatViewModel.buildFeed([msg(9), msg(6), msg(2)], members: [],
                                           unreadMarker: (anchorSeq: 6, count: 2),
                                           unreadableSeqs: [3, 4, 7, 8],
                                           atHistoryStart: true)
        let ids = feed.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "feed item ids must be unique: \(ids)")
        XCTAssertEqual(unreadableIds(feed), ["gap:7-8", "gap:3-4"])
    }

    @MainActor
    func testRunsGroupConsecutiveSeqs() {
        XCTAssertEqual(ChatViewModel.runs(of: [4, 5, 6, 9, 11, 12]), [4...6, 9...9, 11...12])
        XCTAssertEqual(ChatViewModel.runs(of: []), [])
        XCTAssertEqual(ChatViewModel.runs(of: [7, 7]), [7...7])
    }
}
