import XCTest
@testable import Msngr

/// The rule matrix for the "N unread messages" marker.
final class UnreadMarkerStateTests: XCTestCase {

    // Rule 1: entering with unread puts the marker above the first unread message
    func testEnterChatWithUnread() {
        var s = UnreadMarkerState()
        s.enterChat(unreadCount: 5, myReadUpTo: 10)
        XCTAssertTrue(s.isActive)
        XCTAssertEqual(s.anchorSeq, 11)
        XCTAssertEqual(s.count, 5)
    }

    func testEnterChatWithoutUnread() {
        var s = UnreadMarkerState()
        s.enterChat(unreadCount: 0, myReadUpTo: 10)
        XCTAssertFalse(s.isActive)
        XCTAssertNil(s.anchorSeq)
    }

    // Rule 2: incoming messages in a visible chat grow the active marker's counter
    func testIncomingIncrementsActiveMarker() {
        var s = UnreadMarkerState()
        s.enterChat(unreadCount: 5, myReadUpTo: 10)
        s.incoming(seq: 16)
        XCTAssertEqual(s.count, 6)
        XCTAssertEqual(s.anchorSeq, 11, "the anchor does not move when the counter grows")
    }

    // with no active marker, an incoming message in a visible chat creates none
    func testIncomingWithoutMarkerDoesNothing() {
        var s = UnreadMarkerState()
        s.enterChat(unreadCount: 0, myReadUpTo: 10)
        s.incoming(seq: 11)
        XCTAssertFalse(s.isActive)
    }

    // Rule 3: your own send or reaction removes the marker
    func testDismissClearsMarker() {
        var s = UnreadMarkerState()
        s.enterChat(unreadCount: 5, myReadUpTo: 10)
        s.dismiss()
        XCTAssertFalse(s.isActive)
        XCTAssertNil(s.anchorSeq)
        XCTAssertEqual(s.count, 0)
    }

    // after a dismiss, incoming messages do not revive the marker while the screen stays visible
    func testIncomingAfterDismissDoesNothing() {
        var s = UnreadMarkerState()
        s.enterChat(unreadCount: 5, myReadUpTo: 10)
        s.dismiss()
        s.incoming(seq: 16)
        XCTAssertFalse(s.isActive)
    }

    // Rule 4: going to the background or behind the shade removes the marker
    func testObscuredDismissesMarker() {
        var s = UnreadMarkerState()
        s.enterChat(unreadCount: 5, myReadUpTo: 10)
        s.becameObscured()
        XCTAssertFalse(s.isActive)
    }

    // Rule 5: what arrived while away gets a fresh marker on return
    func testMessagesWhileObscuredShowMarkerOnReturn() {
        var s = UnreadMarkerState()
        s.enterChat(unreadCount: 0, myReadUpTo: 10)
        s.becameObscured()
        s.incoming(seq: 11)
        s.incoming(seq: 12)
        s.incoming(seq: 13)
        XCTAssertFalse(s.isActive, "while the screen is not visible there is no marker")
        s.becameActive()
        XCTAssertTrue(s.isActive)
        XCTAssertEqual(s.anchorSeq, 11, "the anchor is the first message that arrived while away")
        XCTAssertEqual(s.count, 3)
    }

    func testReturnWithoutNewMessagesShowsNoMarker() {
        var s = UnreadMarkerState()
        s.enterChat(unreadCount: 5, myReadUpTo: 10)
        s.becameObscured()
        s.becameActive()
        XCTAssertFalse(s.isActive, "the old marker does not come back after the background")
    }

    // a second background→return cycle does not carry the old pending count over
    func testObscuredCycleResetsPending() {
        var s = UnreadMarkerState()
        s.becameObscured()
        s.incoming(seq: 11)
        s.becameActive()
        XCTAssertEqual(s.count, 1)
        s.becameObscured()
        s.becameActive()
        XCTAssertFalse(s.isActive)
    }

    // after returning to a fresh marker, incoming messages keep growing the counter
    func testIncomingAfterReturnIncrements() {
        var s = UnreadMarkerState()
        s.becameObscured()
        s.incoming(seq: 11)
        s.becameActive()
        s.incoming(seq: 12)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.anchorSeq, 11)
    }

    // plural forms in the marker's title
    func testMarkerTitlePluralization() {
        XCTAssertEqual(UnreadMarkerCell.title(count: 1), "1 непрочитанное сообщение")
        XCTAssertEqual(UnreadMarkerCell.title(count: 2), "2 непрочитанных сообщения")
        XCTAssertEqual(UnreadMarkerCell.title(count: 5), "5 непрочитанных сообщений")
        XCTAssertEqual(UnreadMarkerCell.title(count: 11), "11 непрочитанных сообщений")
        XCTAssertEqual(UnreadMarkerCell.title(count: 21), "21 непрочитанное сообщение")
        XCTAssertEqual(UnreadMarkerCell.title(count: 104), "104 непрочитанных сообщения")
    }
}
