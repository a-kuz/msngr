import XCTest
import GRDB
@testable import MsngrCore

/// The per-member marks behind the read-by list: what `recordMark` writes,
/// `memberMarks` reads back, for everyone in the chat but the caller.
final class MemberMarksTests: XCTestCase {
    func testMarksComeBackForEveryPeerButNotMe() throws {
        let db = try AppDatabase.openInMemory()
        try db.write { dbc in
            try SyncEngine.recordMark(dbc, chatId: "c1", userId: "bob", upToSeq: 5, isRead: true)
            try SyncEngine.recordMark(dbc, chatId: "c1", userId: "carol", upToSeq: 3, isRead: false)
            try SyncEngine.recordMark(dbc, chatId: "c1", userId: "me", upToSeq: 9, isRead: true)
            try SyncEngine.recordMark(dbc, chatId: "other", userId: "bob", upToSeq: 8, isRead: true)
        }
        let marks = try db.read { try SyncEngine.memberMarks($0, chatId: "c1", ownUserId: "me") }
        XCTAssertEqual(marks["bob"], MemberMark(deliveredUpTo: 5, readUpTo: 5))
        XCTAssertEqual(marks["carol"], MemberMark(deliveredUpTo: 3, readUpTo: 0))
        XCTAssertNil(marks["me"])
        XCTAssertEqual(marks.count, 2)
    }
}
