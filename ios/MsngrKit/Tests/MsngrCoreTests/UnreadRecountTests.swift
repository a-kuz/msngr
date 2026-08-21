import XCTest
import GRDB
@testable import MsngrCore

/// The unread number across an offline gap is estimated in seqs and then
/// settled onto rows once the chat is caught up: service frames, tombstones
/// and system messages fall out, envelopes still waiting for a key stay in.
final class UnreadRecountTests: XCTestCase {
    private func seedChat(_ db: DatabaseQueue, id: String = "c1",
                          lastSeq: Int, syncedSeq: Int, myReadUpTo: Int,
                          unreadCount: Int) throws {
        var chat = Chat(id: id, kind: .direct, title: nil, createdBy: "peer", createdAt: 0,
                        lastSeq: lastSeq, syncedSeq: syncedSeq, lastActivityAt: 0)
        chat.myReadUpTo = myReadUpTo
        chat.unreadCount = unreadCount
        try db.write { dbc in try chat.save(dbc) }
    }

    private func msg(_ db: DatabaseQueue, seq: Int, kind: MessageKind = .text,
                     outgoing: Bool = false, deletedForAll: Bool = false) throws {
        var m = Message(id: "m\(seq)", chatId: "c1", fromUserId: outgoing ? "me" : "peer",
                        sentAt: Double(seq), kind: kind, text: "t\(seq)",
                        status: .sent, isOutgoing: outgoing)
        m.seq = seq
        m.deletedForAll = deletedForAll
        try db.write { dbc in try m.save(dbc) }
    }

    /// Three seqs beyond the read mark, of which one is a real incoming
    /// message: the seq estimate said 3, the rows say 1.
    func testServiceSeqsAndTombstonesFallOut() throws {
        let db = try AppDatabase.openInMemory()
        // seq 21 was deleted for everyone (no row), 22 is the message,
        // 23 was the edit's service frame (no row)
        try seedChat(db, lastSeq: 23, syncedSeq: 23, myReadUpTo: 20, unreadCount: 3)
        try msg(db, seq: 20, outgoing: true)
        try msg(db, seq: 22)

        try db.write { dbc in
            try SyncEngine.recountUnread(dbc, chatId: "c1", ownUserId: "me")
        }
        let n = try db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT unreadCount FROM chat WHERE id = 'c1'")
        }
        XCTAssertEqual(n, 1)
    }

    /// A chat that is still behind keeps its estimate: the rows are not the
    /// truth until the contiguous prefix reaches the end.
    func testChatStillBehindKeepsTheEstimate() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, lastSeq: 23, syncedSeq: 21, myReadUpTo: 20, unreadCount: 3)
        try msg(db, seq: 22)

        try db.write { dbc in
            try SyncEngine.recountUnread(dbc, chatId: "c1", ownUserId: "me")
        }
        let n = try db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT unreadCount FROM chat WHERE id = 'c1'")
        }
        XCTAssertEqual(n, 3)
    }

    /// A tombstoned row and a system message raise nothing; an envelope still
    /// waiting for its key counts as the message it is.
    func testPendingDecryptCountsAndSystemDoesNot() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, lastSeq: 24, syncedSeq: 24, myReadUpTo: 20, unreadCount: 4)
        try msg(db, seq: 21, deletedForAll: true)
        try msg(db, seq: 22, kind: .system)
        try msg(db, seq: 23)
        try db.write { dbc in
            try dbc.execute(sql: """
                INSERT INTO pendingDecrypt (chatId, msgId, seq, fromUserId, fromDevice,
                                            sentAt, ts, body)
                VALUES ('c1', 'mx', 24, 'peer', 'd1', 0, 0, x'7b7d')
                """)
        }

        try db.write { dbc in
            try SyncEngine.recountUnread(dbc, chatId: "c1", ownUserId: "me")
        }
        let n = try db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT unreadCount FROM chat WHERE id = 'c1'")
        }
        XCTAssertEqual(n, 2)
    }
}
