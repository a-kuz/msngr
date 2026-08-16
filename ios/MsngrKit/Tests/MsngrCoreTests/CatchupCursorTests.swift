import XCTest
import GRDB
@testable import MsngrCore

/// Catch-up is pulled portion by portion: the server confirms how far it
/// replayed each chat, the client stores that cursor and resumes from it.
final class CatchupCursorTests: XCTestCase {
    private func makeEngine(db: DatabaseQueue) throws -> SyncEngine {
        let api = APIClient(baseURL: URL(string: "http://localhost:1")!)
        let store = try IdentityStore(db: db, masterKeyProvider: StaticMasterKey())
        let e2ee = E2EEManager(store: store, api: api, ownUserId: "me", ownDeviceId: "dev")
        return SyncEngine(db: db, api: api, e2ee: e2ee,
                          wsURL: URL(string: "ws://localhost:1/ws")!,
                          ownUserId: "me", ownDeviceId: "dev")
    }

    private func seedChat(_ db: DatabaseQueue, id: String = "c1",
                          lastSeq: Int, syncedSeq: Int, syncCursor: Int = 0) throws {
        var chat = Chat(id: id, kind: .direct, title: nil, createdBy: "peer", createdAt: 0,
                        lastSeq: lastSeq, syncedSeq: syncedSeq, lastActivityAt: 0)
        chat.syncCursor = syncCursor
        try db.write { dbc in try chat.save(dbc) }
    }

    private func frame(_ obj: [String: Any]) throws -> WSIncoming {
        let data = try JSONSerialization.data(withJSONObject: obj)
        return try JSONDecoder().decode(WSIncoming.self, from: data)
    }

    // MARK: - Cursor of the next portion

    /// A seq this device never receives — a message held back by a block, a
    /// tombstone — stalls the contiguous prefix, and the catch-up cursor is
    /// what carries the next portion past it.
    func testCursorResumesFromTheConfirmedPosition() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, lastSeq: 300, syncedSeq: 40, syncCursor: 128)
        try seedChat(db, id: "c2", lastSeq: 10, syncedSeq: 10, syncCursor: 0)

        let cursors = try db.read { dbc in try HistoryWindow.catchupCursors(dbc) }
        XCTAssertEqual(cursors["c1"], 128)
        // nothing to catch up on: the contiguous prefix already reaches the end
        XCTAssertEqual(cursors["c2"], 10)
    }

    // MARK: - Progress of a portion

    /// The cursor is confirmed after the portion is applied and survives the
    /// connection: the next run starts where this one stopped.
    func testPortionStoresItsCursor() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try seedChat(db, lastSeq: 300, syncedSeq: 0)

        await engine.apply(try frame(["t": "syncState", "chatId": "c1",
                                      "cursor": 128, "more": true]))
        let cursor = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT syncCursor FROM chat WHERE id = 'c1'")
        }
        XCTAssertEqual(cursor, 128)
    }

    /// A portion that arrives late must not pull the catch-up back: the cursor
    /// only ever moves forward.
    func testStaleCursorDoesNotRollBack() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try seedChat(db, lastSeq: 300, syncedSeq: 0, syncCursor: 256)

        await engine.apply(try frame(["t": "syncState", "chatId": "c1",
                                      "cursor": 128, "more": true]))
        let cursor = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT syncCursor FROM chat WHERE id = 'c1'")
        }
        XCTAssertEqual(cursor, 256)
    }

    /// The messages of a portion are applied before its cursor is confirmed, so
    /// a run cut off mid-portion resumes at a position everything below which
    /// is already in the database.
    func testCursorIsConfirmedAfterTheMessagesOfThePortion() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try seedChat(db, lastSeq: 300, syncedSeq: 0)

        for seq in 1...3 {
            await engine.storeHistoric(content: {
                var c = ContentPayload(kind: "text")
                c.text = "msg \(seq)"
                return c
            }(), chatId: "c1", msgId: "m\(seq)", seq: seq, from: "peer",
                                      sentAt: Double(seq), ts: Double(seq))
        }
        await engine.apply(try frame(["t": "syncState", "chatId": "c1",
                                      "cursor": 3, "more": false]))

        let stored = try await db.read { dbc -> (Int, Int) in
            let msgs = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = 'c1' AND seq <= 3")!
            let cursor = try Int.fetchOne(dbc, sql: "SELECT syncCursor FROM chat WHERE id = 'c1'")!
            return (msgs, cursor)
        }
        XCTAssertEqual(stored.0, 3)
        XCTAssertEqual(stored.1, 3)
    }

    // MARK: - Frames

    func testCatchupFrameCarriesTheCursors() throws {
        let data = try WSOutgoing.catchup(cursors: ["c1": 128]).encode()
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["t"] as? String, "catchup")
        XCTAssertEqual((obj["cursors"] as? [String: Int])?["c1"], 128)
    }
}
