import XCTest
import GRDB
@testable import MsngrCore

/// The number on the icon: one source, and an order between the writers that
/// keeps it from walking backwards while messages arrive.
final class BadgeStoreTests: XCTestCase {
    private func seedChat(_ db: DatabaseQueue, id: String, unread: Int,
                          isRequest: Bool = false, accepted: Bool = true) throws {
        var chat = Chat(id: id, kind: .direct, title: nil, createdBy: "peer",
                        createdAt: 0, lastSeq: unread, syncedSeq: 0, lastActivityAt: 0)
        chat.unreadCount = unread
        chat.isRequest = isRequest
        chat.iAccepted = accepted
        try db.write { dbc in try chat.save(dbc) }
    }

    func testStartsAtZero() throws {
        let db = try AppDatabase.openInMemory()
        XCTAssertEqual(try db.read { try BadgeStore.current($0) }, 0)
    }

    /// The counts the server produced arrive in an arbitrary order; the icon
    /// follows the order the server produced them in.
    func testLatePushDoesNotPutAnOlderCountBack() throws {
        let db = try AppDatabase.openInMemory()
        try db.write { dbc in
            XCTAssertEqual(try BadgeStore.applyFromPush(dbc, value: 130, stamp: 12), 130)
            XCTAssertEqual(try BadgeStore.applyFromPush(dbc, value: 149, stamp: 20), 149)
            // the push carrying 139 was sent before the one carrying 149
            XCTAssertEqual(try BadgeStore.applyFromPush(dbc, value: 139, stamp: 15), 149)
            XCTAssertEqual(try BadgeStore.applyFromPush(dbc, value: 87, stamp: 9), 149)
        }
    }

    /// A whole burst delivered in shuffled order lands on the newest count, and
    /// the icon never shows a number older than one it already showed.
    func testShuffledBurstEndsOnTheNewestCount() throws {
        let db = try AppDatabase.openInMemory()
        let counts = (1...60).map { (value: $0, stamp: $0) }.shuffled()
        var seenStamps: [Int] = []
        try db.write { dbc in
            for c in counts {
                let shown = try BadgeStore.applyFromPush(dbc, value: c.value, stamp: c.stamp)
                seenStamps.append(shown)
            }
        }
        XCTAssertEqual(try db.read { try BadgeStore.current($0) }, 60)
        XCTAssertEqual(seenStamps, seenStamps.sorted(), "the icon walked backwards")
    }

    /// The count the server sends is the whole answer after an offline stretch:
    /// the device never saw the pushes that were collapsed away, and a counter
    /// it incremented itself would be short by exactly those.
    func testOfflineBurstLandsOnTheServerCount() throws {
        let db = try AppDatabase.openInMemory()
        try db.write { dbc in
            XCTAssertEqual(try BadgeStore.applyFromPush(dbc, value: 2, stamp: 1), 2)
            // 50 messages arrived while the device was offline and only the
            // last push survived
            XCTAssertEqual(try BadgeStore.applyFromPush(dbc, value: 52, stamp: 51), 52)
        }
    }

    /// Reading is the app's own knowledge and lowers the icon without waiting
    /// for a push; the next count from the server still wins.
    func testLocalReadLowersTheCount() throws {
        let db = try AppDatabase.openInMemory()
        try db.write { dbc in
            XCTAssertEqual(try BadgeStore.applyFromPush(dbc, value: 9, stamp: 30), 9)
            XCTAssertEqual(try BadgeStore.applyLocal(dbc, value: 0), 0)
            XCTAssertEqual(try BadgeStore.applyFromPush(dbc, value: 1, stamp: 31), 1)
            // and a push that predates the read is still ignored
            XCTAssertEqual(try BadgeStore.applyFromPush(dbc, value: 9, stamp: 29), 1)
        }
    }

    func testNegativeCountIsNotStored() throws {
        let db = try AppDatabase.openInMemory()
        try db.write { dbc in
            XCTAssertEqual(try BadgeStore.applyFromPush(dbc, value: -3, stamp: 1), 0)
            XCTAssertEqual(try BadgeStore.applyLocal(dbc, value: -3), 0)
        }
    }

    /// A chat waiting to be accepted does not tell how much was written into
    /// it — the same rule the server applies to the count it sends.
    func testLocalUnreadSkipsChatsWaitingToBeAccepted() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, id: "c1", unread: 3)
        try seedChat(db, id: "c2", unread: 7, isRequest: true, accepted: false)
        XCTAssertEqual(try db.read { try BadgeStore.localUnread($0) }, 3)
    }

    /// A push without its place in the sequence cannot be ordered, so it is not
    /// taken as a badge at all.
    func testPushedBadgeNeedsBothFields() throws {
        XCTAssertNil(BadgeStore.pushedBadge(from: ["badgeStamp": 4], badge: nil))
        XCTAssertNil(BadgeStore.pushedBadge(from: [:], badge: 5))
        let got = BadgeStore.pushedBadge(from: ["badgeStamp": 4], badge: 5)
        XCTAssertEqual(got?.value, 5)
        XCTAssertEqual(got?.stamp, 4)
    }
}
