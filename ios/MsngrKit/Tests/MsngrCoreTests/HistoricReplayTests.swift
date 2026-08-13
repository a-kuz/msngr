import XCTest
import GRDB
@testable import MsngrCore

/// Применение сообщений из серверной истории (пагинация вверх):
/// edit/reaction ложатся поверх оригиналов, порядок реплея не важен.
final class HistoricReplayTests: XCTestCase {
    private func makeEngine(db: DatabaseQueue) throws -> SyncEngine {
        let api = APIClient(baseURL: URL(string: "http://localhost:1")!)
        let store = try IdentityStore(db: db, masterKeyProvider: StaticMasterKey())
        let e2ee = E2EEManager(store: store, api: api, ownUserId: "me", ownDeviceId: "dev")
        return SyncEngine(db: db, api: api, e2ee: e2ee,
                          wsURL: URL(string: "ws://localhost:1/ws")!,
                          ownUserId: "me", ownDeviceId: "dev")
    }

    /// reaction и edit в историческом реплее применяются к оригиналу.
    func testHistoricReactionAndEditApplyToOriginal() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)

        var original = ContentPayload(kind: "text")
        original.text = "привет"
        await engine.storeHistoric(content: original, chatId: "c1", msgId: "m1",
                                   seq: 1, from: "peer", sentAt: 1, ts: 1)

        var reaction = ContentPayload(kind: "reaction")
        reaction.targetMsgId = "m1"
        reaction.emoji = "👍"
        await engine.storeHistoric(content: reaction, chatId: "c1", msgId: "r1",
                                   seq: 2, from: "peer", sentAt: 2, ts: 2)

        var edit = ContentPayload(kind: "edit")
        edit.targetMsgId = "m1"
        edit.text = "привет!"
        await engine.storeHistoric(content: edit, chatId: "c1", msgId: "e1",
                                   seq: 3, from: "peer", sentAt: 3, ts: 3)

        let row = try await db.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT text, edited, reactions FROM message WHERE msgId = 'm1'")!
        }
        XCTAssertEqual(row["text"] as String, "привет!")
        XCTAssertEqual(row["edited"] as Bool, true)
        let reactions = try JSONDecoder().decode([String: [String]].self,
                                                 from: Data((row["reactions"] as String).utf8))
        XCTAssertEqual(reactions["👍"], ["peer"])
        // служебные фреймы не создали собственных строк в ленте
        let count = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = 'c1'")!
        }
        XCTAssertEqual(count, 1)
    }

    /// reaction из истории раньше своего оригинала буферизуется в pendingApply
    /// и применяется при появлении оригинала.
    func testHistoricReactionBeforeOriginalBuffersAndApplies() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)

        var reaction = ContentPayload(kind: "reaction")
        reaction.targetMsgId = "m1"
        reaction.emoji = "❤️"
        await engine.storeHistoric(content: reaction, chatId: "c1", msgId: "r1",
                                   seq: 2, from: "peer", sentAt: 2, ts: 2)

        let buffered = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM pendingApply WHERE targetMsgId = 'm1'")!
        }
        XCTAssertEqual(buffered, 1)

        var original = ContentPayload(kind: "text")
        original.text = "оригинал"
        await engine.storeHistoric(content: original, chatId: "c1", msgId: "m1",
                                   seq: 1, from: "peer", sentAt: 1, ts: 1)

        let row = try await db.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT reactions FROM message WHERE msgId = 'm1'")!
        }
        let reactions = try JSONDecoder().decode([String: [String]].self,
                                                 from: Data((row["reactions"] as String).utf8))
        XCTAssertEqual(reactions["❤️"], ["peer"])
        let left = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM pendingApply")!
        }
        XCTAssertEqual(left, 0)
    }

    /// Повторный реплей того же диапазона идемпотентен (upsert по msgId).
    func testHistoricReplayIdempotent() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        var original = ContentPayload(kind: "text")
        original.text = "раз"
        await engine.storeHistoric(content: original, chatId: "c1", msgId: "m1",
                                   seq: 1, from: "peer", sentAt: 1, ts: 1)
        await engine.storeHistoric(content: original, chatId: "c1", msgId: "m1",
                                   seq: 1, from: "peer", sentAt: 1, ts: 1)
        let count = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = 'c1'")!
        }
        XCTAssertEqual(count, 1)
    }
}
