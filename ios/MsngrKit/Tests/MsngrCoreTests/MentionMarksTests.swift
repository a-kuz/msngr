import XCTest
import GRDB
@testable import MsngrCore

/// The «@» mark on a chat row: it lights up while an unread message mentions
/// you, and goes out once the mention is read, deleted or was your own doing.
final class MentionMarksTests: XCTestCase {
    private func seed(_ db: DatabaseQueue) throws {
        try db.write { dbc in
            try Chat(id: "c1", kind: .group, title: "Trio", createdBy: "peer", createdAt: 0,
                     lastSeq: 0, syncedSeq: 0, lastActivityAt: 0).save(dbc)
        }
    }

    private func message(_ dbc: GRDB.Database, seq: Int, text: String, own: Bool = false) throws {
        var msg = Message(id: "m\(seq)", chatId: "c1", fromUserId: own ? "me" : "peer",
                          sentAt: Double(seq), kind: .text, text: text,
                          status: .sent, isOutgoing: own)
        msg.seq = seq
        try msg.save(dbc)
    }

    private func mark(_ db: DatabaseQueue, readUpTo: Int) throws -> Bool {
        try db.read { dbc in
            try MentionMarks.hasUnreadMention(dbc, chatId: "c1", myReadUpTo: readUpTo,
                                              ownUserId: "me")
        }
    }

    func testAnUnreadMentionLightsTheMark() throws {
        let db = try AppDatabase.openInMemory()
        try seed(db)
        try db.write { dbc in
            try message(dbc, seq: 1, text: "plain")
            try message(dbc, seq: 2, text: "эй [@Я](user:me), глянь")
        }
        XCTAssertTrue(try mark(db, readUpTo: 0))
        // reading past the mention puts the mark out
        XCTAssertFalse(try mark(db, readUpTo: 2))
    }

    func testTheCounterAndTheEarliestTarget() throws {
        let db = try AppDatabase.openInMemory()
        try seed(db)
        try db.write { dbc in
            try message(dbc, seq: 1, text: "старое [@Я](user:me)")
            try message(dbc, seq: 2, text: "plain")
            try message(dbc, seq: 3, text: "и ещё [@Я](user:me)")
        }
        let all = try db.read { try MentionMarks.unreadMentions($0, chatId: "c1",
                                                                myReadUpTo: 0, ownUserId: "me") }
        XCTAssertEqual(all?.count, 2)
        XCTAssertEqual(all?.earliestId, "m1")
        let tail = try db.read { try MentionMarks.unreadMentions($0, chatId: "c1",
                                                                 myReadUpTo: 1, ownUserId: "me") }
        XCTAssertEqual(tail?.count, 1)
        XCTAssertEqual(tail?.earliestId, "m3")
        XCTAssertNil(try db.read { try MentionMarks.unreadMentions($0, chatId: "c1",
                                                                   myReadUpTo: 3, ownUserId: "me") })
    }

    /// An unread «@все» lights the mark the way a personal mention does.
    func testTheGroupWideMentionLightsTheMark() throws {
        let db = try AppDatabase.openInMemory()
        try seed(db)
        try db.write { dbc in
            try message(dbc, seq: 1, text: "собрание, [@все](user:all)")
        }
        XCTAssertTrue(try mark(db, readUpTo: 0))
        XCTAssertFalse(try mark(db, readUpTo: 1))
    }

    func testPlainUnreadAndForeignMentionsStayDark() throws {
        let db = try AppDatabase.openInMemory()
        try seed(db)
        try db.write { dbc in
            try message(dbc, seq: 1, text: "plain unread")
            try message(dbc, seq: 2, text: "для [@Другого](user:someoneElse)")
            try message(dbc, seq: 3, text: "своё [@Я](user:me)", own: true)
        }
        XCTAssertFalse(try mark(db, readUpTo: 0))
    }
}
