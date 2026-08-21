import XCTest
import GRDB
@testable import MsngrCore

/// Disappearing messages: the deadline is stamped on incoming messages, on our own,
/// and on ones paged in from history, and the sweep takes what has expired off the
/// device.
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

    /// Our own message gets its deadline at the moment it went out: while it sits in
    /// the queue without a network there is nothing to count down.
    func testOwnMessageGetsItsDeadlineFromTheAck() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try await makeChat(db, ttl: 60)

        var content = ContentPayload(kind: "text")
        content.text = "will disappear"
        try await engine.enqueue(content: content, chatId: "c1", clientMsgId: "local-1")
        var expires = try await db.read { dbc in
            try Double.fetchOne(dbc, sql: "SELECT expiresAt FROM message WHERE id = 'local-1'")
        }
        XCTAssertNil(expires, "an unsent message has no clock to run from")

        await engine.apply(try JSONDecoder().decode(WSIncoming.self, from: Data("""
        {"t":"sent","chatId":"c1","clientMsgId":"local-1","seq":1,"ts":2}
        """.utf8)))
        expires = try await db.read { dbc in
            try Double.fetchOne(dbc, sql: "SELECT expiresAt FROM message WHERE id = 'local-1'")
        }
        XCTAssertNotNil(expires)
        XCTAssertEqual(expires!, Date().timeIntervalSince1970 + 60, accuracy: 5)
    }

    /// What is paged in from history is stamped the same way, or paging up would
    /// bring back what has already expired, and it would stay forever.
    func testHistoricMessageGetsDeadline() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try await makeChat(db, ttl: 60)

        var content = ContentPayload(kind: "text")
        content.text = "an old one"
        await engine.storeHistoric(content: content, chatId: "c1", seq: 9,
                                   from: "peer", sentAt: 1, ts: 1)

        let expires = try await db.read { dbc in
            try Double.fetchOne(dbc, sql: "SELECT expiresAt FROM message WHERE chatId = 'c1' AND seq = 9")
        }
        XCTAssertNotNil(expires)
    }

    /// The sweep takes the expired and leaves the rest. A seq above syncedSeq is
    /// closed off with a historyGap row: without it pagination would ask the server
    /// again for a range whose keys are already gone.
    func testSweepRemovesExpiredAndClosesTheGap() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try await makeChat(db, ttl: 60)
        let now = Date().timeIntervalSince1970
        try await db.write { dbc in
            try dbc.execute(sql: """
                INSERT INTO message (id, chatId, seq, fromUserId, sentAt, kind, status, isOutgoing, expiresAt)
                VALUES ('m1','c1',5,'peer',1,'text',1,0,?)
                """, arguments: [now - 1])
            try dbc.execute(sql: """
                INSERT INTO message (id, chatId, seq, fromUserId, sentAt, kind, status, isOutgoing, expiresAt)
                VALUES ('m2','c1',6,'peer',1,'text',1,0,?)
                """, arguments: [now + 600])
            try dbc.execute(sql: """
                INSERT INTO message (id, chatId, seq, fromUserId, sentAt, kind, status, isOutgoing)
                VALUES ('m3','c1',7,'peer',1,'text',1,0)
                """)
        }

        await engine.sweepExpiredMessages()

        let (left, gap) = try await db.read { dbc in
            (try String.fetchAll(dbc, sql: "SELECT id FROM message ORDER BY id"),
             try Int.fetchAll(dbc, sql: "SELECT seq FROM historyGap WHERE chatId = 'c1'"))
        }
        XCTAssertEqual(left, ["m2", "m3"])
        XCTAssertEqual(gap, [5], "the expired seq is closed off so it is not asked for again")
    }

    /// A chat with no TTL stamps no deadlines and the sweep does not touch it.
    func testChatWithoutTTLKeepsEverything() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try await makeChat(db, ttl: 0)

        var content = ContentPayload(kind: "text")
        content.text = "stays put"
        await engine.applyContent(content, chatId: "c1", seq: 1,
                                  from: "peer", sentAt: 1, ts: 1)
        await engine.sweepExpiredMessages()

        let count = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = 'c1'")!
        }
        XCTAssertEqual(count, 1)
    }
}
