import XCTest
import GRDB
@testable import MsngrCore

/// Исчезающие сообщения: срок ставится и входящим, и своим, и подгруженным из
/// истории, а свип уносит с устройства то, чему срок вышел.
final class DisappearingTests: XCTestCase {
    private func makeEngine(db: DatabaseQueue) throws -> SyncEngine {
        let api = APIClient(baseURL: URL(string: "http://localhost:1")!)
        let store = try IdentityStore(db: db, masterKeyProvider: StaticMasterKey())
        let e2ee = E2EEManager(store: store, api: api, ownUserId: "me", ownDeviceId: "dev")
        return SyncEngine(db: db, api: api, e2ee: e2ee,
                          wsURL: URL(string: "ws://localhost:1/ws")!,
                          ownUserId: "me", ownDeviceId: "dev")
    }

    private func makeChat(_ db: DatabaseQueue, ttl: Int) async throws {
        try await db.write { dbc in
            try dbc.execute(sql: """
                INSERT INTO chat (id, kind, createdBy, createdAt, ttlSeconds, syncedSeq)
                VALUES ('c1','direct','peer',0,?,0)
                """, arguments: [ttl])
        }
    }

    /// Своё сообщение получает срок в момент, когда оно ушло: пока оно лежит в
    /// очереди без сети, отсчитывать нечего.
    func testOwnMessageGetsItsDeadlineFromTheAck() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try await makeChat(db, ttl: 60)

        var content = ContentPayload(kind: "text")
        content.text = "исчезнет"
        try await engine.enqueue(content: content, chatId: "c1", clientMsgId: "local-1")
        var expires = try await db.read { dbc in
            try Double.fetchOne(dbc, sql: "SELECT expiresAt FROM message WHERE id = 'local-1'")
        }
        XCTAssertNil(expires, "не отправленному сроку идти неоткуда")

        await engine.apply(try JSONDecoder().decode(WSIncoming.self, from: Data("""
        {"t":"sent","chatId":"c1","clientMsgId":"local-1","msgId":"srv-1","seq":1,"ts":2}
        """.utf8)))
        expires = try await db.read { dbc in
            try Double.fetchOne(dbc, sql: "SELECT expiresAt FROM message WHERE id = 'local-1'")
        }
        XCTAssertNotNil(expires)
        XCTAssertEqual(expires!, Date().timeIntervalSince1970 + 60, accuracy: 5)
    }

    /// Подгруженное из истории помечается так же, иначе пагинация вверх
    /// возвращала бы то, чему срок вышел, и оно оставалось бы навсегда.
    func testHistoricMessageGetsDeadline() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try await makeChat(db, ttl: 60)

        var content = ContentPayload(kind: "text")
        content.text = "старое"
        await engine.storeHistoric(content: content, chatId: "c1", msgId: "srv-9", seq: 9,
                                   from: "peer", sentAt: 1, ts: 1)

        let expires = try await db.read { dbc in
            try Double.fetchOne(dbc, sql: "SELECT expiresAt FROM message WHERE msgId = 'srv-9'")
        }
        XCTAssertNotNil(expires)
    }

    /// Свип уносит просроченное и оставляет остальное. Seq выше syncedSeq
    /// закрывается записью historyGap: без неё пагинация снова просила бы у
    /// сервера диапазон, ключей к которому уже нет.
    func testSweepRemovesExpiredAndClosesTheGap() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try await makeChat(db, ttl: 60)
        let now = Date().timeIntervalSince1970
        try await db.write { dbc in
            try dbc.execute(sql: """
                INSERT INTO message (id, chatId, msgId, seq, fromUserId, sentAt, kind, status, isOutgoing, expiresAt)
                VALUES ('m1','c1','m1',5,'peer',1,'text',1,0,?)
                """, arguments: [now - 1])
            try dbc.execute(sql: """
                INSERT INTO message (id, chatId, msgId, seq, fromUserId, sentAt, kind, status, isOutgoing, expiresAt)
                VALUES ('m2','c1','m2',6,'peer',1,'text',1,0,?)
                """, arguments: [now + 600])
            try dbc.execute(sql: """
                INSERT INTO message (id, chatId, msgId, seq, fromUserId, sentAt, kind, status, isOutgoing)
                VALUES ('m3','c1','m3',7,'peer',1,'text',1,0)
                """)
        }

        await engine.sweepExpiredMessages()

        let (left, gap) = try await db.read { dbc in
            (try String.fetchAll(dbc, sql: "SELECT id FROM message ORDER BY id"),
             try Int.fetchAll(dbc, sql: "SELECT seq FROM historyGap WHERE chatId = 'c1'"))
        }
        XCTAssertEqual(left, ["m2", "m3"])
        XCTAssertEqual(gap, [5], "просроченный seq закрыт, чтобы его не просили заново")
    }

    /// Чат без TTL сроков не проставляет и свипом не задевается.
    func testChatWithoutTTLKeepsEverything() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try await makeChat(db, ttl: 0)

        var content = ContentPayload(kind: "text")
        content.text = "остаётся"
        await engine.applyContent(content, chatId: "c1", msgId: "srv-1", seq: 1,
                                  from: "peer", sentAt: 1, ts: 1)
        await engine.sweepExpiredMessages()

        let count = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = 'c1'")!
        }
        XCTAssertEqual(count, 1)
    }
}
