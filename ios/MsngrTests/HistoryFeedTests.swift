import XCTest
@testable import Msngr
import MsngrCore

/// Лента вокруг нечитаемых сообщений и начала истории.
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

    /// Нечитаемый seq между двумя сообщениями окна: одна заглушка на месте дыры.
    @MainActor
    func testUnreadableSeqBetweenMessagesBecomesOneItem() {
        let feed = ChatViewModel.buildFeed([msg(5), msg(3)], members: [], unreadableSeqs: [4])
        XCTAssertEqual(unreadableIds(feed), ["gap:4-4"])
        // заглушка стоит между сообщениями: лента инвертирована, старое ниже по массиву
        let ids = feed.map(\.id)
        XCTAssertLessThan(ids.firstIndex(of: "m5")!, ids.firstIndex(of: "gap:4-4")!)
        XCTAssertLessThan(ids.firstIndex(of: "gap:4-4")!, ids.firstIndex(of: "m3")!)
    }

    /// Подряд идущие нечитаемые seq собираются в одну заглушку, а не в череду.
    @MainActor
    func testAdjacentUnreadableSeqsCollapse() {
        let feed = ChatViewModel.buildFeed([msg(10), msg(5)], members: [],
                                           unreadableSeqs: [6, 7, 8, 9])
        XCTAssertEqual(unreadableIds(feed), ["gap:6-9"])
    }

    /// Разрыв ниже самого старого сообщения окна — это ещё не догруженный низ,
    /// заглушку он не получает.
    @MainActor
    func testGapBelowOldestLoadedMessageHasNoPlaceholder() {
        let feed = ChatViewModel.buildFeed([msg(9), msg(8)], members: [], unreadableSeqs: [3, 4])
        XCTAssertTrue(unreadableIds(feed).isEmpty)
    }

    /// Дошли до самого старого сообщения на устройстве — в самом верху ленты
    /// один элемент, а не заглушка на каждое недостающее сообщение.
    @MainActor
    func testHistoryStartIsASingleItemAtTheTop() {
        let feed = ChatViewModel.buildFeed([msg(9), msg(8)], members: [], atHistoryStart: true)
        guard case .historyStart = feed.last else {
            return XCTFail("последний элемент ленты — начало истории, получено \(String(describing: feed.last))")
        }
        XCTAssertEqual(feed.filter { if case .historyStart = $0 { return true } else { return false } }.count, 1)
    }

    /// Пустая лента элемента «история начинается здесь» не получает.
    @MainActor
    func testEmptyFeedHasNoHistoryStart() {
        XCTAssertTrue(ChatViewModel.buildFeed([], members: [], atHistoryStart: true).isEmpty)
    }

    /// Плашка непрочитанных и заглушки уживаются: id элементов уникальны.
    @MainActor
    func testFeedIdsStayUnique() {
        let feed = ChatViewModel.buildFeed([msg(9), msg(6), msg(2)], members: [],
                                           unreadMarker: (anchorSeq: 6, count: 2),
                                           unreadableSeqs: [3, 4, 7, 8],
                                           atHistoryStart: true)
        let ids = feed.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "id элементов ленты должны быть уникальны: \(ids)")
        XCTAssertEqual(unreadableIds(feed), ["gap:7-8", "gap:3-4"])
    }

    @MainActor
    func testRunsGroupConsecutiveSeqs() {
        XCTAssertEqual(ChatViewModel.runs(of: [4, 5, 6, 9, 11, 12]), [4...6, 9...9, 11...12])
        XCTAssertEqual(ChatViewModel.runs(of: []), [])
        XCTAssertEqual(ChatViewModel.runs(of: [7, 7]), [7...7])
    }
}
