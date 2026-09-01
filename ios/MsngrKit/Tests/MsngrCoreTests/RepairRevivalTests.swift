import XCTest
import GRDB
@testable import MsngrCore

/// An envelope from a peer that finally opens says the session with him works
/// again. Everything of his that was given up on while it did not is worth one
/// more round — without it a pair that fell behind keeps its holes for good
/// even after the two of them can talk again.
final class RepairRevivalTests: XCTestCase {
    private func pending(_ db: DatabaseQueue, seq: Int, from: String,
                         attempts: Int, age: Double) async throws {
        let now = Date().timeIntervalSince1970
        try await db.write { dbc in
            try dbc.execute(sql: """
                INSERT INTO pendingDecrypt (chatId, seq, fromUserId, fromDevice, sentAt, ts,
                                            body, reason, attempts, firstSeenAt, lastTriedAt,
                                            repairAttempts, repairAskedAt)
                VALUES ('c1', ?, ?, 'd1', 1, 1, x'00', 'no_session', 1, ?, ?, ?, ?)
                """, arguments: [seq, from, now - age, now - age, attempts, now - age])
        }
    }

    func testSpentRepairsAreGivenAnotherRound() async throws {
        let db = try AppDatabase.openInMemory()
        try await pending(db, seq: 1, from: "peer", attempts: MessageRepair.maxAttempts, age: 3600)
        try await pending(db, seq: 2, from: "peer", attempts: 2, age: 3600)
        try await pending(db, seq: 3, from: "other", attempts: MessageRepair.maxAttempts, age: 3600)

        let revived = try await db.write { dbc in
            try SyncEngine.reviveSpentRepairs(dbc, from: "peer")
        }
        XCTAssertEqual(revived, 1, "only the spent ones of that peer")

        let state = try await db.read { dbc in
            (one: try Int.fetchOne(dbc, sql: "SELECT repairAttempts FROM pendingDecrypt WHERE seq = 1")!,
             two: try Int.fetchOne(dbc, sql: "SELECT repairAttempts FROM pendingDecrypt WHERE seq = 2")!,
             three: try Int.fetchOne(dbc, sql: "SELECT repairAttempts FROM pendingDecrypt WHERE seq = 3")!)
        }
        XCTAssertEqual(state.one, 0, "the given-up envelope asks again")
        XCTAssertEqual(state.two, 2, "one still in flight keeps its count")
        XCTAssertEqual(state.three, MessageRepair.maxAttempts, "another peer is not touched")
    }

    /// An envelope past the life it is kept for has nothing to be asked about,
    /// and the sweep can only drop it while its attempts read as spent — so the
    /// revival leaves it alone.
    func testAnEnvelopePastItsLifeIsLeftForTheSweep() async throws {
        let db = try AppDatabase.openInMemory()
        try await pending(db, seq: 1, from: "peer", attempts: MessageRepair.maxAttempts,
                          age: MessageRepair.envelopeTTL + 3600)

        let revived = try await db.write { dbc in
            try SyncEngine.reviveSpentRepairs(dbc, from: "peer")
        }
        XCTAssertEqual(revived, 0)
        let attempts = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT repairAttempts FROM pendingDecrypt WHERE seq = 1")!
        }
        XCTAssertEqual(attempts, MessageRepair.maxAttempts)
    }

    /// A stream of arrivals must not revive the same pile over and over.
    func testTheRevivalHasAWindow() {
        XCTAssertFalse(MessageRepair.repairRevivalDue(lastRevivedAt: 100, now: 200))
        XCTAssertTrue(MessageRepair.repairRevivalDue(
            lastRevivedAt: 100, now: 100 + MessageRepair.repairRevivalInterval))
    }
}
