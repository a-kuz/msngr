import XCTest
import GRDB
@testable import MsngrCore

/// The number on the chat row counts what the reader will be shown. A frame
/// that takes a seq without showing anything — an edit, a reaction, the sender
/// key handed out after the roster changed, the system line of a group event —
/// must leave it where it is.
final class UnreadCountTests: XCTestCase {
    private func seedChat(_ db: DatabaseQueue) throws {
        try db.write { dbc in
            let chat = Chat(id: "c1", kind: .group, title: "Trio", createdBy: "peer", createdAt: 0,
                            lastSeq: 0, syncedSeq: 0, lastActivityAt: 0)
            try chat.save(dbc)
        }
    }

    /// One incoming message, written the way the sync engine writes it.
    private func incoming(_ dbc: GRDB.Database, seq: Int, kind: MessageKind = .text,
                          from: String = "peer") throws {
        var msg = Message(id: "m\(seq)", chatId: "c1", fromUserId: from, sentAt: Double(seq),
                          kind: kind, text: "hi", status: .sent, isOutgoing: from == "me")
        msg.seq = seq
        try msg.save(dbc)
    }

    private func unread(_ db: DatabaseQueue) throws -> Int {
        try db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT unreadCount FROM chat WHERE id = 'c1'") ?? -1
        }
    }

    /// A rowless service frame between two messages: two messages arrived, and
    /// two is what the row says.
    func testServiceFrameDoesNotGrowTheCount() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db)

        try db.write { dbc in
            try incoming(dbc, seq: 1)
            try SyncEngine.advanceChat(dbc, chatId: "c1", seq: 1, isOwn: false, isService: false)
        }
        XCTAssertEqual(try unread(db), 1)

        // an edit or a reaction: a seq is spent, nothing is shown
        try db.write { dbc in
            try SyncEngine.advanceChat(dbc, chatId: "c1", seq: 2, isOwn: false, isService: true)
        }
        XCTAssertEqual(try unread(db), 1, "a frame with nothing to show must not be counted")

        try db.write { dbc in
            try incoming(dbc, seq: 3)
            try SyncEngine.advanceChat(dbc, chatId: "c1", seq: 3, isOwn: false, isService: false)
        }
        XCTAssertEqual(try unread(db), 2)
    }

    /// A group event has a line in the feed and is still not a message: joining
    /// and leaving must not raise the number either.
    func testGroupEventDoesNotGrowTheCount() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db)
        try db.write { dbc in
            try incoming(dbc, seq: 1)
            try SyncEngine.advanceChat(dbc, chatId: "c1", seq: 1, isOwn: false, isService: false)
            try incoming(dbc, seq: 2, kind: .system)
            try SyncEngine.advanceChat(dbc, chatId: "c1", seq: 2, isOwn: false, isService: true)
        }

        XCTAssertEqual(try unread(db), 1)
    }

    /// A frame delivered twice is still one message: the queue may replay a
    /// batch, and the count has to survive it.
    func testRedeliveryDoesNotDoubleCount() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db)
        try db.write { dbc in
            try incoming(dbc, seq: 1)
            try SyncEngine.advanceChat(dbc, chatId: "c1", seq: 1, isOwn: false, isService: false)
            try SyncEngine.advanceChat(dbc, chatId: "c1", seq: 1, isOwn: false, isService: false)
        }

        XCTAssertEqual(try unread(db), 1)
    }

    /// Our own message from another device: everything before it is read, so the
    /// number goes to nothing.
    func testOwnMessageClearsTheCount() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db)
        try db.write { dbc in
            try incoming(dbc, seq: 1)
            try SyncEngine.advanceChat(dbc, chatId: "c1", seq: 1, isOwn: false, isService: false)
            try incoming(dbc, seq: 2, from: "me")
            try SyncEngine.advanceChat(dbc, chatId: "c1", seq: 2, isOwn: true, isService: false)
        }

        XCTAssertEqual(try unread(db), 0)
    }
}
