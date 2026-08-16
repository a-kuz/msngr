import XCTest
import GRDB
@testable import MsngrCore

/// Служебные фреймы и буфер edit/reaction/deleted без оригинала.
/// Сервер не нужен — движок создаётся с недоступным адресом.
final class ServiceFrameTests: XCTestCase {
    private func makeEngine(db: DatabaseQueue) throws -> SyncEngine {
        let api = APIClient(baseURL: URL(string: "http://localhost:1")!)
        let store = try IdentityStore(db: db, masterKeyProvider: StaticMasterKey())
        let e2ee = E2EEManager(store: store, api: api, ownUserId: "me", ownDeviceId: "dev")
        return SyncEngine(db: db, api: api, e2ee: e2ee,
                          wsURL: URL(string: "ws://localhost:1/ws")!,
                          ownUserId: "me", ownDeviceId: "dev")
    }

    private func msgFrame(seq: Int, msgId: String, service: Bool) throws -> WSIncoming {
        let json = """
        {"t":"msg","chatId":"c1","seq":\(seq),"msgId":"\(msgId)","from":"peer","fromDevice":"d1",
        "sentAt":1,"ts":1,"body":{"v":1,"mode":"skm","c":"AA==","keyId":"k1","iteration":0,"sig":"AA=="}
        \(service ? #","service":true"# : "")}
        """
        return try JSONDecoder().decode(WSIncoming.self, from: Data(json.utf8))
    }

    /// msg с service=true двигает lastSeq/syncedSeq, но unreadCount не растёт;
    /// следующее обычное сообщение считается без учёта служебного seq.
    func testServiceFrameDoesNotGrowUnread() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try await db.write { dbc in
            try dbc.execute(sql: "INSERT INTO chat (id, kind, createdBy, createdAt) VALUES ('c1','group','peer',0)")
        }

        await engine.apply(try msgFrame(seq: 1, msgId: "m1", service: true))
        var row = try await db.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT lastSeq, syncedSeq, unreadCount, myReadUpTo FROM chat WHERE id = 'c1'")!
        }
        XCTAssertEqual(row["lastSeq"] as Int, 1)
        XCTAssertEqual(row["syncedSeq"] as Int, 1)
        XCTAssertEqual(row["unreadCount"] as Int, 0)
        XCTAssertEqual(row["myReadUpTo"] as Int, 1) // прочитанный чат поглотил служебный seq

        // обычное сообщение после служебного: непрочитанным считается только оно
        await engine.apply(try msgFrame(seq: 2, msgId: "m2", service: false))
        row = try await db.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT lastSeq, unreadCount FROM chat WHERE id = 'c1'")!
        }
        XCTAssertEqual(row["lastSeq"] as Int, 2)
        XCTAssertEqual(row["unreadCount"] as Int, 1)
    }

    /// Реакция и правка на сообщение, которого ещё нет в БД (оригинал ждёт ключа),
    /// буферизуются и применяются при появлении строки.
    func testReactionAndEditBeforeOriginalApplyAfter() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)

        var reaction = ContentPayload(kind: "reaction")
        reaction.targetMsgId = "m1"
        reaction.emoji = "👍"
        await engine.applyContent(reaction, chatId: "c1", msgId: "r1", seq: 2,
                                  from: "peer", sentAt: 1, ts: 1)
        var edit = ContentPayload(kind: "edit")
        edit.targetMsgId = "m1"
        edit.text = "исправлено"
        await engine.applyContent(edit, chatId: "c1", msgId: "e1", seq: 3,
                                  from: "peer", sentAt: 1, ts: 1)

        let buffered = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM pendingApply WHERE targetMsgId = 'm1'")!
        }
        XCTAssertEqual(buffered, 2)

        // оригинал расшифровался и вставился — буфер применяется и очищается
        var original = ContentPayload(kind: "text")
        original.text = "оригинал"
        await engine.applyContent(original, chatId: "c1", msgId: "m1", seq: 1,
                                  from: "peer", sentAt: 1, ts: 1)

        let row = try await db.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT text, edited, reactions FROM message WHERE msgId = 'm1'")!
        }
        XCTAssertEqual(row["text"] as String, "исправлено")
        XCTAssertEqual(row["edited"] as Bool, true)
        let reactions = try JSONDecoder().decode([String: [String]].self,
                                                 from: Data((row["reactions"] as String).utf8))
        XCTAssertEqual(reactions["👍"], ["peer"])
        let left = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM pendingApply")!
        }
        XCTAssertEqual(left, 0)
    }

    /// Реакция на собственное сообщение, поставленная до ack: пока у цели нет
    /// серверного msgId, отправлять нечего — иначе собеседник получил бы
    /// локальный id, которого у него никогда не будет.
    func testReactionToUnackedTargetResolvesAtSendTime() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try await db.write { dbc in
            try dbc.execute(sql: "INSERT INTO chat (id, kind, createdBy, createdAt) VALUES ('c1','direct','me',0)")
            // своё сообщение, ack ещё не пришёл: msgId пуст, id локальный
            try dbc.execute(sql: """
                INSERT INTO message (id, chatId, clientMsgId, fromUserId, sentAt, kind, status, isOutgoing)
                VALUES ('local-1','c1','local-1','me',1,'text',0,1)
                """)
        }
        var reaction = ContentPayload(kind: "reaction")
        reaction.targetMsgId = "local-1"
        reaction.emoji = "👍"

        do {
            _ = try await engine.resolveTarget(reaction, chatId: "c1")
            XCTFail("реакция не должна уехать с локальным id")
        } catch let e as SyncEngine.TargetNotAcked {
            XCTAssertFalse(e.gone, "цель ещё может уехать — ждём ack, а не выбрасываем")
        }

        // ack пришёл — цель подставляется серверным id
        let ack = try JSONDecoder().decode(WSIncoming.self, from: Data("""
        {"t":"sent","chatId":"c1","clientMsgId":"local-1","msgId":"srv-1","seq":1,"ts":2}
        """.utf8))
        await engine.apply(ack)
        let resolved = try await engine.resolveTarget(reaction, chatId: "c1")
        XCTAssertEqual(resolved.targetMsgId, "srv-1")
    }

    /// Цель от собеседника: её id уже серверный, подстановка ничего не меняет.
    /// Цель, которая так и не ушла: служебный фрейм выбрасывается.
    func testTargetFromPeerPassesThroughAndFailedTargetIsDropped() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try await db.write { dbc in
            try dbc.execute(sql: "INSERT INTO chat (id, kind, createdBy, createdAt) VALUES ('c1','direct','me',0)")
            try dbc.execute(sql: """
                INSERT INTO message (id, chatId, msgId, fromUserId, sentAt, kind, status, isOutgoing)
                VALUES ('srv-9','c1','srv-9','peer',1,'text',1,0)
                """)
            try dbc.execute(sql: """
                INSERT INTO message (id, chatId, clientMsgId, fromUserId, sentAt, kind, status, isOutgoing)
                VALUES ('local-2','c1','local-2','me',1,'text',-1,1)
                """)
        }
        var edit = ContentPayload(kind: "edit")
        edit.targetMsgId = "srv-9"
        edit.text = "исправлено"
        let fromPeer = try await engine.resolveTarget(edit, chatId: "c1")
        XCTAssertEqual(fromPeer.targetMsgId, "srv-9")

        edit.targetMsgId = "local-2"
        do {
            _ = try await engine.resolveTarget(edit, chatId: "c1")
            XCTFail("правка сообщения, которое не ушло, отправляться не должна")
        } catch let e as SyncEngine.TargetNotAcked {
            XCTAssertTrue(e.gone)
        }
    }

    /// Ack освобождает служебные фреймы, ждавшие серверный id своей цели.
    func testAckReleasesWaitingOutboxRows() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try await db.write { dbc in
            try dbc.execute(sql: "INSERT INTO chat (id, kind, createdBy, createdAt) VALUES ('c1','direct','me',0)")
            try OutboxItem(clientMsgId: "r1", chatId: "c1", createdAt: 2,
                           payload: Data("{}".utf8), state: "waiting").save(dbc)
        }
        let ack = try JSONDecoder().decode(WSIncoming.self, from: Data("""
        {"t":"sent","chatId":"c1","clientMsgId":"local-1","msgId":"srv-1","seq":1,"ts":2}
        """.utf8))
        await engine.apply(ack)

        let state = try await db.read { dbc in
            try String.fetchOne(dbc, sql: "SELECT state FROM outbox WHERE clientMsgId = 'r1'")
        }
        XCTAssertEqual(state, "ready")
    }

    /// deleted раньше оригинала буферизуется; повторный deleted (sync-реплей) идемпотентен.
    func testDeletedBeforeOriginalAndReplay() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        let deleted = try JSONDecoder().decode(WSIncoming.self, from: Data("""
        {"t":"deleted","chatId":"c1","msgIds":["m1"],"forAll":true,"by":"peer"}
        """.utf8))

        await engine.apply(deleted)
        var original = ContentPayload(kind: "text")
        original.text = "секрет"
        await engine.applyContent(original, chatId: "c1", msgId: "m1", seq: 1,
                                  from: "peer", sentAt: 1, ts: 1)
        await engine.apply(deleted) // реплей после появления строки

        let row = try await db.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT deletedForAll, text FROM message WHERE msgId = 'm1'")!
        }
        XCTAssertEqual(row["deletedForAll"] as Bool, true)
        XCTAssertNil(row["text"] as String?)
    }
}
