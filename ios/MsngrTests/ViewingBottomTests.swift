import XCTest
@testable import Msngr

/// "The feed is at the bottom": the criterion behind the scroll-to-bottom button
/// and the read mark. The list is inverted, so the newest item is item 0.
final class ViewingBottomTests: XCTestCase {
    func testNewestVisibleMeansBottom() {
        XCTAssertTrue(MessagesViewController.isAtBottom(visibleItems: [0, 1, 2], totalItems: 3))
    }

    func testScrolledUpIsNotBottom() {
        XCTAssertFalse(MessagesViewController.isAtBottom(visibleItems: [7, 8, 9], totalItems: 40))
    }

    /// Opening a chat with unread messages: the feed stops at the marker with a few
    /// hundred points left below it, yet the newest messages are on screen.
    func testUnreadMarkerOnScreenWithNewestVisible() {
        XCTAssertTrue(MessagesViewController.isAtBottom(visibleItems: [0, 1, 2, 3, 4], totalItems: 120))
    }

    /// More unread than fits the screen: the marker is up top and the end of the feed
    /// is off screen.
    func testUnreadMarkerAboveScreenWithNewestHidden() {
        XCTAssertFalse(MessagesViewController.isAtBottom(visibleItems: [10, 11, 12, 13], totalItems: 120))
    }

    func testEmptyFeedIsBottom() {
        XCTAssertTrue(MessagesViewController.isAtBottom(visibleItems: [], totalItems: 0))
    }

    /// There are items but no cells yet (layout has not run): that is not the bottom.
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
