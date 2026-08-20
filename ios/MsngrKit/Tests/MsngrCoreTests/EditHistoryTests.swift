import XCTest
import GRDB
@testable import MsngrCore

/// What an edited message keeps: every text it has shown, oldest first, each
/// stamped with the time it was authored. The history survives replays and the
/// edit-before-original path.
final class EditHistoryTests: XCTestCase {
    private func makeEngine(db: DatabaseQueue) throws -> SyncEngine {
        let api = APIClient(baseURL: URL(string: "http://localhost:1")!)
        let store = try IdentityStore(db: db, masterKeyProvider: StaticMasterKey())
        let e2ee = E2EEManager(store: store, api: api, ownUserId: "me", ownDeviceId: "dev")
        return SyncEngine(db: db, api: api, e2ee: e2ee,
                          wsURL: URL(string: "ws://localhost:1/ws")!,
                          ownUserId: "me", ownDeviceId: "dev")
    }

    private func insertOriginal(_ db: DatabaseQueue, text: String, sentAt: Double) async throws {
        try await db.write { dbc in
            var msg = Message(id: "m1", chatId: "c1", fromUserId: "peer", sentAt: sentAt,
                              kind: .text, text: text, status: .sent, isOutgoing: false)
            msg.msgId = "m1"
            msg.seq = 1
            try msg.save(dbc)
        }
    }

    private func edit(_ text: String) -> ContentPayload {
        var c = ContentPayload(kind: "edit")
        c.targetMsgId = "m1"
        c.text = text
        return c
    }

    private func fetch(_ db: DatabaseQueue) async throws -> Message {
        try await db.read { dbc in try Message.fetchOne(dbc, key: "m1")! }
    }

    func testEditKeepsThePreviousText() async throws {
        let db = try AppDatabase.openInMemory()
        try await insertOriginal(db, text: "first", sentAt: 100)

        try await db.write { dbc in
            try SyncEngine.applyContent(dbc, self.edit("second"), chatId: "c1", msgId: "e1",
                                        seq: 2, from: "peer", sentAt: 200, ts: 200, ownUserId: "me")
        }
        let msg = try await fetch(db)
        XCTAssertEqual(msg.text, "second")
        XCTAssertTrue(msg.edited)
        XCTAssertEqual(msg.editedAt, 200)
        XCTAssertEqual(msg.editHistory, [EditVersion(text: "first", ts: 100)])
    }

    func testSecondEditAppendsInOrder() async throws {
        let db = try AppDatabase.openInMemory()
        try await insertOriginal(db, text: "first", sentAt: 100)
        try await db.write { dbc in
            try SyncEngine.applyContent(dbc, self.edit("second"), chatId: "c1", msgId: "e1",
                                        seq: 2, from: "peer", sentAt: 200, ts: 200, ownUserId: "me")
            try SyncEngine.applyContent(dbc, self.edit("third"), chatId: "c1", msgId: "e2",
                                        seq: 3, from: "peer", sentAt: 300, ts: 300, ownUserId: "me")
        }
        let msg = try await fetch(db)
        XCTAssertEqual(msg.text, "third")
        XCTAssertEqual(msg.editHistory, [EditVersion(text: "first", ts: 100),
                                         EditVersion(text: "second", ts: 200)])
    }

    /// Catch-up and gap fills replay frames the device has already applied: the
    /// same edit coming again must not write a duplicate history entry.
    func testReplayedEditAddsNothing() async throws {
        let db = try AppDatabase.openInMemory()
        try await insertOriginal(db, text: "first", sentAt: 100)
        try await db.write { dbc in
            try SyncEngine.applyContent(dbc, self.edit("second"), chatId: "c1", msgId: "e1",
                                        seq: 2, from: "peer", sentAt: 200, ts: 200, ownUserId: "me")
            try SyncEngine.applyContent(dbc, self.edit("second"), chatId: "c1", msgId: "e1",
                                        seq: 2, from: "peer", sentAt: 200, ts: 200, ownUserId: "me")
        }
        let msg = try await fetch(db)
        XCTAssertEqual(msg.editHistory, [EditVersion(text: "first", ts: 100)])
    }

    /// Going back to an earlier text is a real edit, not a replay: both
    /// transitions stay in the history.
    func testReturningToAnEarlierTextIsKept() async throws {
        let db = try AppDatabase.openInMemory()
        try await insertOriginal(db, text: "first", sentAt: 100)
        try await db.write { dbc in
            try SyncEngine.applyContent(dbc, self.edit("second"), chatId: "c1", msgId: "e1",
                                        seq: 2, from: "peer", sentAt: 200, ts: 200, ownUserId: "me")
            try SyncEngine.applyContent(dbc, self.edit("first"), chatId: "c1", msgId: "e2",
                                        seq: 3, from: "peer", sentAt: 300, ts: 300, ownUserId: "me")
        }
        let msg = try await fetch(db)
        XCTAssertEqual(msg.text, "first")
        XCTAssertEqual(msg.editHistory, [EditVersion(text: "first", ts: 100),
                                         EditVersion(text: "second", ts: 200)])
    }

    /// An edit that outran its original waits in pendingApply; when the original
    /// lands, the history still records the original text with its own time.
    func testEditBeforeOriginalKeepsTheOriginalText() async throws {
        let db = try AppDatabase.openInMemory()
        try await db.write { dbc in
            try SyncEngine.applyContent(dbc, self.edit("second"), chatId: "c1", msgId: "e1",
                                        seq: 2, from: "peer", sentAt: 200, ts: 200, ownUserId: "me")
            var original = ContentPayload(kind: "text")
            original.text = "first"
            try SyncEngine.applyContent(dbc, original, chatId: "c1", msgId: "m1",
                                        seq: 1, from: "peer", sentAt: 100, ts: 100, ownUserId: "me")
        }
        let msg = try await fetch(db)
        XCTAssertEqual(msg.text, "second")
        XCTAssertTrue(msg.edited)
        XCTAssertEqual(msg.editedAt, 200)
        XCTAssertEqual(msg.editHistory, [EditVersion(text: "first", ts: 100)])
    }

    /// Our own edit is applied locally the moment it is queued, and it leaves
    /// the same history an incoming edit does.
    func testOwnEditThroughTheOutboxKeepsHistory() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try await db.write { dbc in
            try dbc.execute(sql: "INSERT INTO chat (id, kind, createdBy, createdAt) VALUES ('c1','direct','me',0)")
            var msg = Message(id: "own1", chatId: "c1", fromUserId: "me", sentAt: 100,
                              kind: .text, text: "draft", status: .sent, isOutgoing: true)
            msg.clientMsgId = "own1"
            try msg.save(dbc)
        }
        var c = ContentPayload(kind: "edit")
        c.targetMsgId = "own1"
        c.text = "final"
        try await engine.enqueue(content: c, chatId: "c1")

        let msg = try await db.read { dbc in try Message.fetchOne(dbc, key: "own1")! }
        XCTAssertEqual(msg.text, "final")
        XCTAssertTrue(msg.edited)
        XCTAssertEqual(msg.editHistory.map(\.text), ["draft"])
        XCTAssertEqual(msg.editHistory.first?.ts, 100)
    }
}
