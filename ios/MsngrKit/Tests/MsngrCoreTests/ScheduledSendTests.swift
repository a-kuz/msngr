import XCTest
import GRDB
@testable import MsngrCore

/// Scheduled send: a message enqueued with `scheduledFor` stays in the outbox
/// until its time, can be moved, edited or dropped before it goes, and is
/// eligible again the moment its time passes — including one whose time
/// passed while nothing was running (the cold-start case).
final class ScheduledSendTests: XCTestCase {
    private func makeEngine(db: DatabaseQueue) throws -> SyncEngine {
        let api = APIClient(baseURL: URL(string: "http://localhost:1")!)
        let store = try IdentityStore(db: db, masterKeyProvider: StaticMasterKey())
        let e2ee = E2EEManager(store: store, api: api, ownUserId: "me", ownDeviceId: "dev")
        return SyncEngine(db: db, api: api, e2ee: e2ee,
                          wsURL: URL(string: "ws://localhost:1/ws")!,
                          ownUserId: "me", ownDeviceId: "dev")
    }

    /// The exact predicate `drainOutbox` selects on: due only once
    /// `scheduledFor` is nil or has passed.
    private func dueClientMsgIds(_ db: DatabaseQueue, now: Double) async throws -> [String] {
        try await db.read { dbc in
            try String.fetchAll(dbc, sql: """
                SELECT clientMsgId FROM outbox
                WHERE state = 'ready' AND (scheduledFor IS NULL OR scheduledFor <= ?)
                ORDER BY createdAt
                """, arguments: [now])
        }
    }

    /// A message scheduled for the future sits in the outbox unsent: the
    /// worker's own selection excludes it until its time.
    func testFutureScheduledSendIsNotYetDue() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        let future = Date().addingTimeInterval(3600).timeIntervalSince1970
        try await engine.enqueue(content: ContentPayload(kind: "text"), chatId: "chat1",
                                 clientMsgId: "c1", scheduledFor: future)

        let due = try await dueClientMsgIds(db, now: Date().timeIntervalSince1970)
        XCTAssertTrue(due.isEmpty)

        let row = try await db.read { dbc in try OutboxItem.fetchOne(dbc, key: "c1") }
        XCTAssertEqual(row?.state, "ready")
        XCTAssertEqual(row?.scheduledFor, future)
    }

    /// A message whose scheduled time already passed — whether that happened
    /// seconds ago or because the app was closed straight through it — is due
    /// exactly like an ordinary send.
    func testOverdueScheduledSendIsDue() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        let past = Date().addingTimeInterval(-30).timeIntervalSince1970
        try await engine.enqueue(content: ContentPayload(kind: "text"), chatId: "chat1",
                                 clientMsgId: "c1", scheduledFor: past)

        let due = try await dueClientMsgIds(db, now: Date().timeIntervalSince1970)
        XCTAssertEqual(due, ["c1"])
    }

    /// Cold start: `start()` alone must not flip an overdue scheduled row to
    /// something the drain would skip — it stays 'ready' with its past
    /// `scheduledFor`, so the very next connect sends it.
    func testStartLeavesOverdueScheduledEligible() async throws {
        let db = try AppDatabase.openInMemory()
        let past = Date().addingTimeInterval(-120).timeIntervalSince1970
        try await db.write { dbc in
            try OutboxItem(clientMsgId: "c1", chatId: "chat1", createdAt: 1,
                           payload: try JSONEncoder().encode(ContentPayload(kind: "text")),
                           scheduledFor: past).save(dbc)
        }
        let engine = try makeEngine(db: db)
        await engine.start()
        let due = try await dueClientMsgIds(db, now: Date().timeIntervalSince1970)
        XCTAssertEqual(due, ["c1"])
        await engine.stop()
    }

    /// Cancelling before the time removes both the outbox entry and the
    /// message it would have sent — nothing is left to show for it.
    func testCancelScheduledRemovesBothRows() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        let future = Date().addingTimeInterval(3600).timeIntervalSince1970
        try await engine.enqueue(content: ContentPayload(kind: "text"), chatId: "chat1",
                                 clientMsgId: "c1", scheduledFor: future)

        await engine.cancelScheduled(clientMsgId: "c1", chatId: "chat1")

        let outbox = try await db.read { dbc in try OutboxItem.fetchOne(dbc, key: "c1") }
        let message = try await db.read { dbc in try Message.fetchOne(dbc, key: "c1") }
        XCTAssertNil(outbox)
        XCTAssertNil(message)
        // the server may already hold the envelope: the recall waits its turn
        // in the action queue, surviving a dead socket
        let recall = try await db.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT type, chatId FROM pendingAction WHERE id = ?",
                             arguments: ["deferCancel:c1"])
        }
        XCTAssertEqual(recall?["type"] as String?, "deferCancel")
        XCTAssertEqual(recall?["chatId"] as String?, "chat1")
    }

    /// The deferred ack parks the row: the server holds the envelope, the
    /// outbox keeps it only for a later reschedule or edit.
    func testDeferredAckParksTheRow() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        let future = Date().addingTimeInterval(3600).timeIntervalSince1970
        try await engine.enqueue(content: ContentPayload(kind: "text"), chatId: "chat1",
                                 clientMsgId: "c1", scheduledFor: future)
        try await db.write { dbc in
            try dbc.execute(sql: "UPDATE outbox SET state = 'inflight' WHERE clientMsgId = 'c1'")
        }

        let frame = try JSONDecoder().decode(
            WSIncoming.self,
            from: Data(#"{"t":"deferred","chatId":"chat1","clientMsgId":"c1","dueAt":1}"#.utf8))
        await engine.apply(frame)

        let row = try await db.read { dbc in try OutboxItem.fetchOne(dbc, key: "c1") }
        XCTAssertEqual(row?.state, "deferred")

        // a reschedule takes it back: the drain re-sends and the same
        // clientMsgId replaces the copy the server holds
        await engine.rescheduleSend(clientMsgId: "c1", to: future + 60)
        let back = try await db.read { dbc in try OutboxItem.fetchOne(dbc, key: "c1") }
        XCTAssertEqual(back?.state, "ready")
        XCTAssertEqual(back?.scheduledFor, future + 60)
    }

    /// A parked send whose `sent` ack was lost — the device was offline at the
    /// deadline — is closed by the author's own journal echo: the msg frame
    /// carries the clientMsgId, the row takes the seq and the outbox empties.
    func testOwnEchoClosesAParkedSend() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        let past = Date().addingTimeInterval(-60).timeIntervalSince1970
        var content = ContentPayload(kind: "text")
        content.text = "left on time"
        try await engine.enqueue(content: content, chatId: "chat1", clientMsgId: "c1",
                                 scheduledFor: past + 30)
        try await db.write { dbc in
            try dbc.execute(sql: "UPDATE outbox SET state = 'deferred' WHERE clientMsgId = 'c1'")
            try dbc.execute(sql: "INSERT INTO chat (id, kind, createdBy, createdAt) VALUES ('chat1','direct','me',0)")
        }

        let frame = try JSONDecoder().decode(
            WSIncoming.self,
            from: Data("""
                {"t":"msg","chatId":"chat1","seq":7,"from":"me","fromDevice":"dev",
                 "sentAt":\(past),"ts":\(past + 30),"clientMsgId":"c1","body":{"v":1}}
                """.utf8))
        await engine.apply(frame)

        let row = try await db.read { dbc in try OutboxItem.fetchOne(dbc, key: "c1") }
        XCTAssertNil(row, "the echo ends the deferred row")
        let msg = try await db.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT seq, scheduledFor FROM message WHERE clientMsgId = 'c1'")
        }
        XCTAssertEqual(msg?["seq"], 7)
        XCTAssertNil(msg?["scheduledFor"] as Double?)
    }

    /// An edit of a parked send returns it to ready: the drain re-encrypts
    /// and the server's copy is replaced under the same clientMsgId.
    func testEditReturnsAParkedSendToReady() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        let future = Date().addingTimeInterval(3600).timeIntervalSince1970
        var content = ContentPayload(kind: "text")
        content.text = "original"
        try await engine.enqueue(content: content, chatId: "chat1", clientMsgId: "c1",
                                 scheduledFor: future)
        try await db.write { dbc in
            try dbc.execute(sql: "UPDATE outbox SET state = 'deferred' WHERE clientMsgId = 'c1'")
        }

        await engine.editScheduledText(clientMsgId: "c1", text: "edited")

        let row = try await db.read { dbc in try OutboxItem.fetchOne(dbc, key: "c1") }
        XCTAssertEqual(row?.state, "ready")
    }

    /// Rescheduling moves the due time on both rows; releasing it (`to: nil`)
    /// makes it due at once, the same as `scheduledFor` never having been set.
    func testRescheduleMovesTimeThenReleaseSendsNow() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        let future = Date().addingTimeInterval(3600).timeIntervalSince1970
        try await engine.enqueue(content: ContentPayload(kind: "text"), chatId: "chat1",
                                 clientMsgId: "c1", scheduledFor: future)

        let laterStill = future + 600
        await engine.rescheduleSend(clientMsgId: "c1", to: laterStill)
        var row = try await db.read { dbc in try OutboxItem.fetchOne(dbc, key: "c1") }
        XCTAssertEqual(row?.scheduledFor, laterStill)

        await engine.rescheduleSend(clientMsgId: "c1", to: nil)
        row = try await db.read { dbc in try OutboxItem.fetchOne(dbc, key: "c1") }
        XCTAssertNil(row?.scheduledFor)
        let due = try await dueClientMsgIds(db, now: Date().timeIntervalSince1970)
        XCTAssertEqual(due, ["c1"])
    }

    /// Editing a scheduled message's text rewrites the row shown in the feed
    /// and the payload the worker will eventually send, in step.
    func testEditScheduledTextRewritesRowAndPayload() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        let future = Date().addingTimeInterval(3600).timeIntervalSince1970
        var content = ContentPayload(kind: "text")
        content.text = "original"
        try await engine.enqueue(content: content, chatId: "chat1", clientMsgId: "c1", scheduledFor: future)

        await engine.editScheduledText(clientMsgId: "c1", text: "edited")

        let message = try await db.read { dbc in try Message.fetchOne(dbc, key: "c1") }
        XCTAssertEqual(message?.text, "edited")
        let payload = try await db.read { dbc in
            try Data.fetchOne(dbc, sql: "SELECT payload FROM outbox WHERE clientMsgId = ?", arguments: ["c1"])
        }
        let decoded = try JSONDecoder().decode(ContentPayload.self, from: payload!)
        XCTAssertEqual(decoded.text, "edited")
    }
}
