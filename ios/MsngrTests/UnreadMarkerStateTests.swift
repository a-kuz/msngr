import XCTest
import GRDB
import MsngrCore
@testable import Msngr

/// The rule matrix for the "N unread messages" marker.
final class UnreadMarkerStateTests: XCTestCase {

    // The count is derived from the database, not incremented per visible row:
    // catch-up appends rows the feed window never shows, and coalesced
    // emissions skip seqs (the live 56-vs-1004 defect).
    func testReconcileLiftsTheCountToTheDerivedTruth() {
        var s = UnreadMarkerState()
        s.enterChat(unreadCount: 700, myReadUpTo: 34)
        s.reconcile(incomingSinceAnchor: 1000)
        XCTAssertEqual(s.count, 1000)
        XCTAssertEqual(s.anchorSeq, 35, "the anchor stays where it was planted")
    }

    func testReconcileKeepsALiveArrivalTheQueryMissed() {
        var s = UnreadMarkerState()
        s.enterChat(unreadCount: 5, myReadUpTo: 10)
        s.incoming(seq: 16)
        s.reconcile(incomingSinceAnchor: 5)
        XCTAssertEqual(s.count, 6, "a +1 that landed after the query is not shrunk away")
    }

    func testReconcileWithoutMarkerDoesNothing() {
        var s = UnreadMarkerState()
        s.reconcile(incomingSinceAnchor: 40)
        XCTAssertFalse(s.isActive)
    }

    // Rule 5 by derivation: arrivals while away that never entered a feed
    // window snapshot still come back as a banner.
    func testPlantRaisesTheReturnBanner() {
        var s = UnreadMarkerState()
        s.becameObscured()
        s.becameActive()
        s.plant(anchorSeq: 11, count: 3)
        XCTAssertTrue(s.isActive)
        XCTAssertEqual(s.anchorSeq, 11)
        XCTAssertEqual(s.count, 3)
    }

    func testPlantWithNothingNewStaysQuiet() {
        var s = UnreadMarkerState()
        s.plant(anchorSeq: 11, count: 0)
        XCTAssertFalse(s.isActive)
    }

    // The derivation queries themselves, over the real schema.
    func testIncomingCountCountsOnlyIncomingFromTheAnchor() throws {
        let db = try AppDatabase.openInMemory()
        try db.write { dbc in
            for seq in 1...12 {
                let own = seq % 4 == 0
                var m = Message(id: "m\(seq)", chatId: "c1", fromUserId: own ? "me" : "peer",
                                sentAt: Double(seq), kind: .text, text: "t",
                                status: .sent, isOutgoing: own)
                m.seq = seq
                try m.save(dbc)
            }
        }
        let n = try db.read { try ChatViewModel.incomingCount($0, chatId: "c1", fromSeq: 5) }
        XCTAssertEqual(n, 6, "seqs 5…12 hold six incoming rows; own messages do not count")
        let all = try db.read { try ChatViewModel.incomingCount($0, chatId: "c1", fromSeq: 1) }
        XCTAssertEqual(all, 9)
    }

    func testFirstArrivalFindsTheFirstUnseenIncoming() throws {
        let db = try AppDatabase.openInMemory()
        try db.write { dbc in
            for (seq, own) in [(20, true), (21, false), (22, false)] {
                var m = Message(id: "m\(seq)", chatId: "c1", fromUserId: own ? "me" : "peer",
                                sentAt: Double(seq), kind: .text, text: "t",
                                status: .sent, isOutgoing: own)
                m.seq = seq
                try m.save(dbc)
            }
        }
        let found = try db.read { try ChatViewModel.firstArrival($0, chatId: "c1", after: 19) }
        XCTAssertEqual(found?.firstSeq, 21, "our own message does not open a banner")
        XCTAssertEqual(found?.count, 2)
        let none = try db.read { try ChatViewModel.firstArrival($0, chatId: "c1", after: 22) }
        XCTAssertNil(none)
    }

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
        XCTAssertEqual(UnreadMarkerCell.title(count: 1), NSString(format: String(localized: "%lld unread messages") as NSString, 1) as String)
        XCTAssertEqual(UnreadMarkerCell.title(count: 2), NSString(format: String(localized: "%lld unread messages") as NSString, 2) as String)
        XCTAssertEqual(UnreadMarkerCell.title(count: 5), NSString(format: String(localized: "%lld unread messages") as NSString, 5) as String)
        XCTAssertEqual(UnreadMarkerCell.title(count: 11), NSString(format: String(localized: "%lld unread messages") as NSString, 11) as String)
        XCTAssertEqual(UnreadMarkerCell.title(count: 21), NSString(format: String(localized: "%lld unread messages") as NSString, 21) as String)
        XCTAssertEqual(UnreadMarkerCell.title(count: 104), NSString(format: String(localized: "%lld unread messages") as NSString, 104) as String)
    }
}
