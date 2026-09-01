import XCTest
import GRDB
@testable import MsngrCore

/// A send waiting for an acknowledgement that will never come. The ack is owed
/// on one socket, so when that socket goes the row has to go back into the
/// queue — otherwise the message sits in flight until the next cold start, and
/// nothing on the screen says so.
final class OutboxRequeueTests: XCTestCase {
    private func item(_ db: DatabaseQueue, id: String, state: String) async throws {
        try await db.write { dbc in
            var row = OutboxItem(clientMsgId: id, chatId: "c1", createdAt: 1, payload: Data())
            row.state = state
            try row.save(dbc)
        }
    }

    func testWhatWasNeverAcknowledgedGoesBackIntoTheQueue() async throws {
        let db = try AppDatabase.openInMemory()
        try await item(db, id: "sent", state: "inflight")
        try await item(db, id: "held", state: "waiting")
        try await item(db, id: "queued", state: "ready")
        try await item(db, id: "stopped", state: "blocked")
        try await item(db, id: "scheduled", state: "deferred")

        let moved = try await db.write { try SyncEngine.requeueUnacked($0) }
        XCTAssertEqual(moved, 2)

        let states = try await db.read { dbc in
            try Row.fetchAll(dbc, sql: "SELECT clientMsgId, state FROM outbox ORDER BY clientMsgId")
                .map { "\($0["clientMsgId"] as String)=\($0["state"] as String)" }
        }
        XCTAssertEqual(states, ["held=ready", "queued=ready", "scheduled=deferred",
                                "sent=ready", "stopped=blocked"],
                       "a stopped send waits for the reader, a scheduled one for its time")
    }

    func testAnEmptyQueueMovesNothing() async throws {
        let db = try AppDatabase.openInMemory()
        let moved = try await db.write { try SyncEngine.requeueUnacked($0) }
        XCTAssertEqual(moved, 0)
    }
}
