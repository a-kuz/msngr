import XCTest
import GRDB
@testable import MsngrCore

/// Офлайн-надёжность: сброс inflight-отправок при старте и схлопывание
/// read-акций в очереди сервисных действий. Сервер не нужен — движок
/// создаётся с недоступным адресом.
final class OfflineReliabilityTests: XCTestCase {
    private func makeEngine(db: DatabaseQueue) throws -> SyncEngine {
        let api = APIClient(baseURL: URL(string: "http://localhost:1")!)
        let store = try IdentityStore(db: db, masterKeyProvider: StaticMasterKey())
        let e2ee = E2EEManager(store: store, api: api, ownUserId: "me", ownDeviceId: "dev")
        return SyncEngine(db: db, api: api, e2ee: e2ee,
                          wsURL: URL(string: "ws://localhost:1/ws")!,
                          ownUserId: "me", ownDeviceId: "dev")
    }

    /// Kill во время отправки: строки outbox, застрявшие в inflight,
    /// при старте возвращаются в ready одним UPDATE.
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

    /// markRead офлайн копится в pendingAction и схлопывается по чату:
    /// одна строка на chatId, побеждает больший upToSeq.
    func testMarkReadCollapsesPerChat() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db) // без start(): офлайн, очередь не дренится

        await engine.markRead(chatId: "chat1", upToSeq: 5)
        await engine.markRead(chatId: "chat1", upToSeq: 9)
        await engine.markRead(chatId: "chat1", upToSeq: 7) // меньший seq не откатывает
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

    /// Заявка до принятия: read-марка не ставится и в очередь не попадает —
    /// автор не должен узнать, что получатель открывал чат.
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

        // после принятия марки снова ходят
        await engine.acceptChatRequest(chatId: "req")
        await engine.markRead(chatId: "req", upToSeq: 3)
        queued = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM pendingAction WHERE type = 'read'")!
        }
        XCTAssertEqual(queued, 1)
    }
}
