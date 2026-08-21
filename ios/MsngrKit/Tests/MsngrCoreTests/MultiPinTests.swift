import XCTest
import GRDB
@testable import MsngrCore

/// A chat holds any number of pinned seqs: pinning appends, re-pinning moves
/// to the end, unpinning removes one, nil clears them all — and every change
/// queues its own action so quick pins cannot swallow each other.
final class MultiPinTests: XCTestCase {
    private func makeEngine(db: DatabaseQueue) throws -> SyncEngine {
        let api = APIClient(baseURL: URL(string: "http://localhost:1")!)
        let store = try IdentityStore(db: db, masterKeyProvider: StaticMasterKey())
        let e2ee = E2EEManager(store: store, api: api, ownUserId: "me", ownDeviceId: "dev")
        return SyncEngine(db: db, api: api, e2ee: e2ee,
                          wsURL: URL(string: "ws://localhost:1/ws")!,
                          ownUserId: "me", ownDeviceId: "dev")
    }

    private func pins(_ db: DatabaseQueue) throws -> [Int] {
        try db.read { dbc in
            let raw = try String.fetchOne(dbc, sql: "SELECT pinnedSeqs FROM chat WHERE id = 'c1'") ?? "[]"
            return (try? JSONDecoder().decode([Int].self, from: Data(raw.utf8))) ?? []
        }
    }

    func testPinSetLifecycle() async throws {
        let db = try AppDatabase.openInMemory()
        try await db.write { dbc in
            try Chat(id: "c1", kind: .direct, title: nil, createdBy: "peer", createdAt: 0,
                     lastSeq: 10, syncedSeq: 10, lastActivityAt: 0).save(dbc)
        }
        let engine = try makeEngine(db: db)

        await engine.pinMessage(chatId: "c1", seq: 3)
        await engine.pinMessage(chatId: "c1", seq: 7)
        XCTAssertEqual(try pins(db), [3, 7])

        // re-pinning moves the seq to the end: the newest pin leads the bar
        await engine.pinMessage(chatId: "c1", seq: 3)
        XCTAssertEqual(try pins(db), [7, 3])

        await engine.pinMessage(chatId: "c1", seq: 7, pinned: false)
        XCTAssertEqual(try pins(db), [3])

        // every seq queues its own action, so both pins reach the server
        let actions = try await db.read { dbc in
            try String.fetchAll(dbc, sql: "SELECT id FROM pendingAction WHERE type = 'pin' ORDER BY id")
        }
        XCTAssertEqual(Set(actions), ["pin:c1:3", "pin:c1:7"])

        await engine.pinMessage(chatId: "c1", seq: nil)
        XCTAssertEqual(try pins(db), [])
    }
}
