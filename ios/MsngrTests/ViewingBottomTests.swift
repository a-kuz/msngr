import XCTest
@testable import Msngr

/// «Лента у низа»: критерий для кнопки «вниз» и отметки прочтения.
/// Список инвертирован — самый новый элемент лежит в item 0.
final class ViewingBottomTests: XCTestCase {
    func testNewestVisibleMeansBottom() {
        XCTAssertTrue(MessagesViewController.isAtBottom(visibleItems: [0, 1, 2], totalItems: 3))
    }

    func testScrolledUpIsNotBottom() {
        XCTAssertFalse(MessagesViewController.isAtBottom(visibleItems: [7, 8, 9], totalItems: 40))
    }

    /// Открытие чата с непрочитанными: лента встаёт на плашку, до низа ленты
    /// остаётся несколько сотен точек, но самые новые сообщения на экране.
    func testUnreadMarkerOnScreenWithNewestVisible() {
        XCTAssertTrue(MessagesViewController.isAtBottom(visibleItems: [0, 1, 2, 3, 4], totalItems: 120))
    }

    /// Непрочитанных больше экрана: плашка вверху, конец ленты за экраном.
    func testUnreadMarkerAboveScreenWithNewestHidden() {
        XCTAssertFalse(MessagesViewController.isAtBottom(visibleItems: [10, 11, 12, 13], totalItems: 120))
    }

    func testEmptyFeedIsBottom() {
        XCTAssertTrue(MessagesViewController.isAtBottom(visibleItems: [], totalItems: 0))
    }

    /// Ячеек ещё нет (раскладка не прогнана), а элементы есть — это не низ.
    func testNoVisibleCellsWithItemsIsNotBottom() {
        XCTAssertFalse(MessagesViewController.isAtBottom(visibleItems: [], totalItems: 5))
    }

    func testOrderOfVisibleItemsDoesNotMatter() {
        XCTAssertTrue(MessagesViewController.isAtBottom(visibleItems: [3, 1, 0, 2], totalItems: 10))
    }

    func testSingleItemFeed() {
        XCTAssertTrue(MessagesViewController.isAtBottom(visibleItems: [0], totalItems: 1))
    }
}
