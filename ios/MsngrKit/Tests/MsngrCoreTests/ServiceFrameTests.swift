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
