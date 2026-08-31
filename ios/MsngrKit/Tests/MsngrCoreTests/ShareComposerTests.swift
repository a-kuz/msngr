import XCTest
import GRDB
@testable import MsngrCore

/// What the share extension leaves behind: a message row the feed can show
/// and an outbox entry the app's worker sends, exactly like a send made
/// offline in the app itself.
final class ShareComposerTests: XCTestCase {
    func testEnqueueLeavesARowAndAReadyOutboxEntry() async throws {
        let db = try AppDatabase.openInMemory()
        try await db.write { dbc in
            try dbc.execute(sql: "INSERT INTO chat (id, kind, createdBy, createdAt) VALUES ('c1','direct','me',0)")
            var c = ContentPayload(kind: "photo")
            var info = MediaInfo(type: "photo", mediaId: "", key: "", hash: "", size: 5, mime: "image/jpeg")
            info.localPath = "pending.jpg"
            c.media = info
            try ShareComposer.enqueue(dbc, content: c, chatId: "c1", ownUserId: "me")
        }
        let (msg, outbox) = try await db.read { dbc in
            (try Message.fetchOne(dbc, sql: "SELECT * FROM message"),
             try OutboxItem.fetchOne(dbc, sql: "SELECT * FROM outbox"))
        }
        XCTAssertEqual(msg?.kind, .photo)
        XCTAssertEqual(msg?.media?.localPath, "pending.jpg")
        XCTAssertEqual(msg?.status, .sending)
        XCTAssertEqual(outbox?.state, "ready")
        XCTAssertEqual(outbox?.chatId, "c1")
        XCTAssertEqual(outbox?.clientMsgId, msg?.clientMsgId)
    }

    func testChatsTitleDirectByPeerAndSkipRequests() async throws {
        let db = try AppDatabase.openInMemory()
        try await db.write { dbc in
            try dbc.execute(sql: """
                INSERT INTO user (id, username, displayName) VALUES ('u2', 'ada', 'Ada Lovelace')
                """)
            try dbc.execute(sql: """
                INSERT INTO chat (id, kind, createdBy, createdAt, title, lastActivityAt)
                VALUES ('direct:me:u2', 'direct', 'me', 0, NULL, 20)
                """)
            try dbc.execute(sql: """
                INSERT INTO chat (id, kind, createdBy, createdAt, title, lastActivityAt)
                VALUES ('g1', 'group', 'me', 0, 'Standup', 10)
                """)
            try dbc.execute(sql: """
                INSERT INTO chat (id, kind, createdBy, createdAt, isRequest, lastActivityAt)
                VALUES ('direct:me:u3', 'direct', 'u3', 0, 1, 30)
                """)
        }
        let rows = try await db.read { try ShareComposer.chats($0, ownUserId: "me") }
        XCTAssertEqual(rows.map(\.title), ["Ada Lovelace", "Standup"],
                       "most recent first, requests stay out")
        XCTAssertEqual(rows.map(\.isGroup), [false, true])
    }
}
