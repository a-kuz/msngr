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

    /// Отклонённая заявка: чат уходит с устройства с тумбстоуном, а блокировка
    /// ждёт сети в очереди. Без очереди снапшот приносил бы заявку обратно, а
    /// собеседник оставался бы разблокированным.
    func testRejectingRequestOfflineQueuesBothHalves() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db) // без start(): офлайн, очередь не дренится
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
        XCTAssertTrue(isBlocked, "инпут-бар гаснет сразу, не дожидаясь сервера")

        let types = try await db.read { dbc in
            try String.fetchSet(dbc, sql: "SELECT type FROM pendingAction")
        }
        XCTAssertEqual(types, ["deleteChat", "block"])
    }

    /// Список заблокированных с сервера не отменяет блокировку, которая ещё
    /// стоит в очереди: иначе решение пользователя откатывалось бы само.
    func testServerListKeepsQueuedBlock() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try await db.write { dbc in
            try dbc.execute(sql: "INSERT INTO user (id, username, displayName) VALUES ('peer','p','P')")
        }
        try await engine.setBlocked(userId: "peer", blocked: true)

        // сервер о блокировке ещё не знает и отвечает пустым списком
        try await db.write { dbc in try SyncEngine.applyBlockedList(dbc, serverIds: []) }
        var isBlocked = try await db.read { dbc in
            try Bool.fetchOne(dbc, sql: "SELECT isBlocked FROM user WHERE id = 'peer'")!
        }
        XCTAssertTrue(isBlocked)

        // очередь доехала — дальше решает сервер
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
