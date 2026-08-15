import XCTest
import GRDB
@testable import MsngrCore

/// Фрейм {t:"error"} от сервера: сопоставление с исходящим по clientMsgId,
/// пометка сообщения неотправленным и выход из outbox.
final class SendFailureTests: XCTestCase {
    private func makeEngine(db: DatabaseQueue) throws -> SyncEngine {
        let api = APIClient(baseURL: URL(string: "http://localhost:1")!)
        let store = try IdentityStore(db: db, masterKeyProvider: StaticMasterKey())
        let e2ee = E2EEManager(store: store, api: api, ownUserId: "me", ownDeviceId: "dev")
        return SyncEngine(db: db, api: api, e2ee: e2ee,
                          wsURL: URL(string: "ws://localhost:1/ws")!,
                          ownUserId: "me", ownDeviceId: "dev")
    }

    /// Кладёт в БД исходящее в состоянии «отправляется» и его строку в outbox.
    private func seedOutgoing(_ db: DatabaseQueue, clientMsgId: String) async throws {
        try await db.write { dbc in
            try dbc.execute(sql: "INSERT INTO chat (id, kind, createdBy, createdAt) VALUES ('c1','direct','me',0)")
            var msg = Message(id: clientMsgId, chatId: "c1", fromUserId: "me", sentAt: 1,
                              kind: .text, text: "привет", status: .sending, isOutgoing: true)
            msg.clientMsgId = clientMsgId
            try msg.save(dbc)
            try OutboxItem(clientMsgId: clientMsgId, chatId: "c1", createdAt: 1,
                           payload: Data("{}".utf8)).save(dbc)
        }
    }

    private func errorFrame(_ code: String, clientMsgId: String) throws -> WSIncoming {
        let json = #"{"t":"error","error":"\#(code)","chatId":"c1","clientMsgId":"\#(clientMsgId)"}"#
        return try JSONDecoder().decode(WSIncoming.self, from: Data(json.utf8))
    }

    func testErrorFrameMarksMessageFailedAndDropsOutbox() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try await seedOutgoing(db, clientMsgId: "cm1")

        await engine.apply(try errorFrame(SendFailure.blocked, clientMsgId: "cm1"))

        let msg = try await db.read { dbc in
            try Message.fetchOne(dbc, sql: "SELECT * FROM message WHERE clientMsgId = 'cm1'")
        }
        XCTAssertEqual(msg?.status, .failed)
        XCTAssertEqual(msg?.failReason, SendFailure.blocked)
        let queued = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM outbox WHERE clientMsgId = 'cm1'")
        }
        XCTAssertEqual(queued, 0, "отвергнутое сервером не должно ретраиться")
    }

    /// Отказ адресуется конкретной отправке: соседнее исходящее не трогается.
    func testErrorFrameTouchesOnlyMatchingClientMsgId() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try await seedOutgoing(db, clientMsgId: "cm1")
        try await db.write { dbc in
            var other = Message(id: "cm2", chatId: "c1", fromUserId: "me", sentAt: 2,
                                kind: .text, text: "второе", status: .sending, isOutgoing: true)
            other.clientMsgId = "cm2"
            try other.save(dbc)
            try OutboxItem(clientMsgId: "cm2", chatId: "c1", createdAt: 2,
                           payload: Data("{}".utf8)).save(dbc)
        }

        await engine.apply(try errorFrame(SendFailure.blocked, clientMsgId: "cm1"))

        let other = try await db.read { dbc in
            try Message.fetchOne(dbc, sql: "SELECT * FROM message WHERE clientMsgId = 'cm2'")
        }
        XCTAssertEqual(other?.status, .sending)
        XCTAssertNil(other?.failReason)
        let queued = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM outbox WHERE clientMsgId = 'cm2'")
        }
        XCTAssertEqual(queued, 1)
    }

    /// Код, которого клиент не знает (сервер ушёл вперёд), сохраняется как есть.
    func testUnknownCodeIsStored() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try await seedOutgoing(db, clientMsgId: "cm1")

        await engine.apply(try errorFrame("teapot", clientMsgId: "cm1"))

        let msg = try await db.read { dbc in
            try Message.fetchOne(dbc, sql: "SELECT * FROM message WHERE clientMsgId = 'cm1'")
        }
        XCTAssertEqual(msg?.status, .failed)
        XCTAssertEqual(msg?.failReason, "teapot")
    }

    /// Успешный ack после отказа снимает пометку: сообщение всё-таки ушло.
    func testSentAckClearsFailReason() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try await seedOutgoing(db, clientMsgId: "cm1")
        await engine.apply(try errorFrame(SendFailure.sendFailed, clientMsgId: "cm1"))

        let ack = #"{"t":"sent","chatId":"c1","clientMsgId":"cm1","msgId":"m1","seq":1,"ts":5}"#
        await engine.apply(try JSONDecoder().decode(WSIncoming.self, from: Data(ack.utf8)))

        let msg = try await db.read { dbc in
            try Message.fetchOne(dbc, sql: "SELECT * FROM message WHERE clientMsgId = 'cm1'")
        }
        XCTAssertEqual(msg?.status, .sent)
        XCTAssertNil(msg?.failReason)
    }

    // MARK: - Тексты

    func testExplanationPerCode() {
        XCTAssertTrue(SendFailure.explanation(SendFailure.blocked).contains("заблокировали"))
        XCTAssertTrue(SendFailure.explanation(SendFailure.notMember).contains("участник"))
        XCTAssertTrue(SendFailure.explanation(SendFailure.identityChanged).contains("Ключ"))
        XCTAssertTrue(SendFailure.explanation(SendFailure.tooManyAttempts).contains("соединение"))
    }

    /// Неизвестный и отсутствующий код дают общий текст, а не пустоту.
    func testExplanationFallback() {
        XCTAssertFalse(SendFailure.explanation("teapot").isEmpty)
        XCTAssertEqual(SendFailure.explanation("teapot"), SendFailure.explanation(nil))
        XCTAssertEqual(SendFailure.explanation(SendFailure.sendFailed), SendFailure.explanation(nil))
    }
}
