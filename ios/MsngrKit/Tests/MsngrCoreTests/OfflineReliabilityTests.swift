import XCTest
import GRDB
@testable import MsngrCore

/// Offline reliability: resetting inflight sends on start and collapsing read
/// actions in the service action queue. No server needed, the engine is built
/// against an address nothing listens on.
final class OfflineReliabilityTests: XCTestCase {
    private func makeEngine(db: DatabaseQueue) throws -> SyncEngine {
        let api = APIClient(baseURL: URL(string: "http://localhost:1")!)
        let store = try IdentityStore(db: db, masterKeyProvider: StaticMasterKey())
        let e2ee = E2EEManager(store: store, api: api, ownUserId: "me", ownDeviceId: "dev")
        return SyncEngine(db: db, api: api, e2ee: e2ee,
                          wsURL: URL(string: "ws://localhost:1/ws")!,
                          ownUserId: "me", ownDeviceId: "dev")
    }

    /// Killed mid-send: outbox rows stuck in inflight go back to ready on
    /// start, in a single UPDATE.
    func testStartResetsInflightToReady() async throws {
        let db = try AppDatabase.openInMemory()
        try await db.write { dbc in
            try OutboxItem(clientMsgId: "c1", chatId: "chat1", createdAt: 1,
                           payload: Data("{}".utf8), state: "inflight").save(dbc)
            try OutboxItem(clientMsgId: "c2", chatId: "chat1", createdAt: 2,
                           payload: Data("{}".utf8)).save(dbc)
        }
        let engine = try makeEngine(db: db)
        await engine.start()
        let states = try await db.read { dbc in
            try String.fetchAll(dbc, sql: "SELECT state FROM outbox ORDER BY createdAt")
        }
        XCTAssertEqual(states, ["ready", "ready"])
        await engine.stop()
    }

    /// Offline markRead accumulates in pendingAction and collapses per chat:
    /// one row per chatId, the larger upToSeq wins.
    func testMarkReadCollapsesPerChat() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db) // no start(): offline, the queue never drains

        await engine.markRead(chatId: "chat1", upToSeq: 5)
        await engine.markRead(chatId: "chat1", upToSeq: 9)
        await engine.markRead(chatId: "chat1", upToSeq: 7) // a smaller seq does not roll it back
        await engine.markRead(chatId: "chat2", upToSeq: 3)

        let rows = try await db.read { dbc in
            try Row.fetchAll(dbc, sql: """
                SELECT chatId, payload FROM pendingAction WHERE type = 'read' ORDER BY chatId
                """)
                .map { (chatId: $0["chatId"] as String, payload: $0["payload"] as String) }
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].chatId, "chat1")
        let p1 = try JSONDecoder().decode(SyncEngine.ReadActionPayload.self, from: Data(rows[0].payload.utf8))
        XCTAssertEqual(p1.upToSeq, 9)
        XCTAssertEqual(rows[1].chatId, "chat2")
        let p2 = try JSONDecoder().decode(SyncEngine.ReadActionPayload.self, from: Data(rows[1].payload.utf8))
        XCTAssertEqual(p2.upToSeq, 3)
    }

    /// A request before it is accepted: no read mark is stored and nothing is
    /// queued, so the author cannot learn that the recipient opened the chat.
    func testMarkReadSkippedForRequestChat() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try await db.write { dbc in
            var chat = Chat(id: "req", kind: .direct, title: nil, createdBy: "peer",
                            createdAt: 1, lastSeq: 3)
            chat.isRequest = true
            chat.iAccepted = false
            try chat.insert(dbc)
        }

        await engine.markRead(chatId: "req", upToSeq: 3)
        var queued = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM pendingAction WHERE type = 'read'")!
        }
        XCTAssertEqual(queued, 0)
        let readUpTo = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT myReadUpTo FROM chat WHERE id = 'req'")!
        }
        XCTAssertEqual(readUpTo, 0)

        // once accepted, marks are sent again
        await engine.acceptChatRequest(chatId: "req")
        await engine.markRead(chatId: "req", upToSeq: 3)
        queued = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM pendingAction WHERE type = 'read'")!
        }
        XCTAssertEqual(queued, 1)
    }

    /// A rejected request: the chat leaves the device with a tombstone, and the
    /// block waits for the network in the queue. Without the queue a snapshot would
    /// bring the request back, and the peer would stay unblocked.
    func testRejectingRequestOfflineQueuesBothHalves() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db) // no start(): offline, the queue does not drain
        try await db.write { dbc in
            var chat = Chat(id: "req", kind: .direct, title: nil, createdBy: "peer",
                            createdAt: 1, lastSeq: 3)
            chat.isRequest = true
            try chat.insert(dbc)
            try dbc.execute(sql: "INSERT INTO user (id, username, displayName) VALUES ('peer','p','P')")
        }

        await engine.deleteChat(chatId: "req")
        try await engine.setBlocked(userId: "peer", blocked: true)

        let (chats, tombstones, isBlocked) = try await db.read { dbc in
            (try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM chat WHERE id = 'req'")!,
             try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM chatTombstone WHERE chatId = 'req'")!,
             try Bool.fetchOne(dbc, sql: "SELECT isBlocked FROM user WHERE id = 'peer'")!)
        }
        XCTAssertEqual(chats, 0)
        XCTAssertEqual(tombstones, 1)
        XCTAssertTrue(isBlocked, "the input bar goes dim at once, without waiting for the server")

        let types = try await db.read { dbc in
            try String.fetchSet(dbc, sql: "SELECT type FROM pendingAction")
        }
        XCTAssertEqual(types, ["deleteChat", "block"])
    }

    /// The blocked list from the server does not cancel a block that is still in the
    /// queue: otherwise the user's decision would roll itself back.
    func testServerListKeepsQueuedBlock() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try await db.write { dbc in
            try dbc.execute(sql: "INSERT INTO user (id, username, displayName) VALUES ('peer','p','P')")
        }
        try await engine.setBlocked(userId: "peer", blocked: true)

        // the server does not know about the block yet and answers with an empty list
        try await db.write { dbc in try SyncEngine.applyBlockedList(dbc, serverIds: []) }
        var isBlocked = try await db.read { dbc in
            try Bool.fetchOne(dbc, sql: "SELECT isBlocked FROM user WHERE id = 'peer'")!
        }
        XCTAssertTrue(isBlocked)

        // the queue got through: from here the server decides
        try await db.write { dbc in
            try dbc.execute(sql: "DELETE FROM pendingAction WHERE type = 'block'")
            try SyncEngine.applyBlockedList(dbc, serverIds: [])
        }
        isBlocked = try await db.read { dbc in
            try Bool.fetchOne(dbc, sql: "SELECT isBlocked FROM user WHERE id = 'peer'")!
        }
        XCTAssertFalse(isBlocked)
    }
}
