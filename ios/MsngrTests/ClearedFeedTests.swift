import XCTest
@testable import Msngr
import MsngrCore

/// Лента чата, историю которого очистили под открытым экраном.
final class ClearedFeedTests: XCTestCase {
    private func msg(_ seq: Int) -> Message {
        var m = Message(id: "m\(seq)", chatId: "c", fromUserId: "peer",
                        sentAt: 1_700_000_000 + Double(seq), kind: .text, text: "m\(seq)",
                        status: .sent, isOutgoing: false)
        m.msgId = "m\(seq)"
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

    /// Пустой снапшот убирает всё со экрана целиком: ни одной старой ячейки,
    /// ни висящей анимации от вставки, которая шла в этот момент.
    @MainActor
    func testClearedChatLeavesNothingOnScreen() {
        let vc = loadedController()
        vc.apply(ChatViewModel.buildFeed([msg(3), msg(2), msg(1)], members: []))
        vc.view.layoutIfNeeded()
        XCTAssertGreaterThan(vc.collectionView.numberOfItems(inSection: 0), 0)

        // сообщение приходит и тут же очистка: обновление ленты застаёт анимацию
        vc.apply(ChatViewModel.buildFeed([msg(4), msg(3), msg(2), msg(1)], members: []))
        vc.apply([])
        vc.view.layoutIfNeeded()

        XCTAssertEqual(vc.collectionView.numberOfItems(inSection: 0), 0)
        XCTAssertTrue(vc.collectionView.visibleCells.isEmpty)
    }

    /// Очищенный чат снова наполняется: первый пришедший после очистки
    /// снапшот встаёт как открытие чата с нуля.
    @MainActor
    func testChatRefillsAfterClearing() {
        let vc = loadedController()
        vc.apply(ChatViewModel.buildFeed([msg(2), msg(1)], members: []))
        vc.apply([])
        vc.apply(ChatViewModel.buildFeed([msg(5)], members: []))
        vc.view.layoutIfNeeded()

        XCTAssertEqual(vc.collectionView.numberOfItems(inSection: 0), 2) // сообщение + дата
    }

    /// Очищенный чат ленты не строит вообще: без сообщений нет ни заглушек
    /// нечитаемых seq, ни отметки начала истории.
    @MainActor
    func testEmptyChatBuildsNoFeedItems() {
        let feed = ChatViewModel.buildFeed([], members: [], unreadableSeqs: [4, 5],
                                           atHistoryStart: true)
        XCTAssertTrue(feed.isEmpty)
    }
}
