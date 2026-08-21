import XCTest
import GRDB
@testable import MsngrCore

/// Applying messages replayed from server history while paging upwards: edits
/// and reactions land on top of their originals whatever order they arrive in.
final class HistoricReplayTests: XCTestCase {
    private func makeEngine(db: DatabaseQueue) throws -> SyncEngine {
        let api = APIClient(baseURL: URL(string: "http://localhost:1")!)
        let store = try IdentityStore(db: db, masterKeyProvider: StaticMasterKey())
        let e2ee = E2EEManager(store: store, api: api, ownUserId: "me", ownDeviceId: "dev")
        return SyncEngine(db: db, api: api, e2ee: e2ee,
                          wsURL: URL(string: "ws://localhost:1/ws")!,
                          ownUserId: "me", ownDeviceId: "dev")
    }

    /// A reaction and an edit replayed from history apply to the original.
    func testHistoricReactionAndEditApplyToOriginal() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)

        var original = ContentPayload(kind: "text")
        original.text = "hello"
        await engine.storeHistoric(content: original, chatId: "c1",
                                   seq: 1, from: "peer", sentAt: 1, ts: 1)

        var reaction = ContentPayload(kind: "reaction")
        reaction.targetSeq = 1
        reaction.emoji = "👍"
        await engine.storeHistoric(content: reaction, chatId: "c1",
                                   seq: 2, from: "peer", sentAt: 2, ts: 2)

        var edit = ContentPayload(kind: "edit")
        edit.targetSeq = 1
        edit.text = "hello!"
        await engine.storeHistoric(content: edit, chatId: "c1",
                                   seq: 3, from: "peer", sentAt: 3, ts: 3)

        let row = try await db.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT text, edited, reactions FROM message WHERE chatId = 'c1' AND seq = 1")!
        }
        XCTAssertEqual(row["text"] as String, "hello!")
        XCTAssertEqual(row["edited"] as Bool, true)
        let reactions = try JSONDecoder().decode([String: [String]].self,
                                                 from: Data((row["reactions"] as String).utf8))
        XCTAssertEqual(reactions["👍"], ["peer"])
        // the service frames created no rows of their own in the feed
        let count = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = 'c1'")!
        }
        XCTAssertEqual(count, 1)
    }

    /// A reaction that arrives from history ahead of its original waits in
    /// pendingApply and is applied once the original shows up.
    func testHistoricReactionBeforeOriginalBuffersAndApplies() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)

        var reaction = ContentPayload(kind: "reaction")
        reaction.targetSeq = 1
        reaction.emoji = "❤️"
        await engine.storeHistoric(content: reaction, chatId: "c1",
                                   seq: 2, from: "peer", sentAt: 2, ts: 2)

        let buffered = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM pendingApply WHERE targetSeq = 1")!
        }
        XCTAssertEqual(buffered, 1)

        var original = ContentPayload(kind: "text")
        original.text = "the original"
        await engine.storeHistoric(content: original, chatId: "c1",
                                   seq: 1, from: "peer", sentAt: 1, ts: 1)

        let row = try await db.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT reactions FROM message WHERE chatId = 'c1' AND seq = 1")!
        }
        let reactions = try JSONDecoder().decode([String: [String]].self,
                                                 from: Data((row["reactions"] as String).utf8))
        XCTAssertEqual(reactions["❤️"], ["peer"])
        let left = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM pendingApply")!
        }
        XCTAssertEqual(left, 0)
    }

    /// Replaying the same range again is idempotent: rows are upserted by (chatId, seq).
    func testHistoricReplayIdempotent() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        var original = ContentPayload(kind: "text")
        original.text = "one"
        await engine.storeHistoric(content: original, chatId: "c1",
                                   seq: 1, from: "peer", sentAt: 1, ts: 1)
        await engine.storeHistoric(content: original, chatId: "c1",
                                   seq: 1, from: "peer", sentAt: 1, ts: 1)
        let count = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = 'c1'")!
        }
        XCTAssertEqual(count, 1)
    }
}
