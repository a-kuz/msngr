import XCTest
import GRDB
@testable import MsngrCore

/// The `listened` event: who started a voice or round video collects on the
/// message, waits for its target when it arrives first, and travels as a
/// service frame that grows no unread.
final class NoteListenedTests: XCTestCase {
    private func insertNote(_ db: DatabaseQueue, seq: Int, outgoing: Bool) async throws {
        try await db.write { dbc in
            var msg = Message(id: "m\(seq)", chatId: "c1", fromUserId: outgoing ? "me" : "peer",
                              sentAt: 100, kind: .voice, text: nil, status: .sent,
                              isOutgoing: outgoing)
            msg.seq = seq
            try msg.save(dbc)
        }
    }

    private func listeners(_ db: DatabaseQueue, seq: Int) async throws -> [String] {
        try await db.read { dbc in
            try Message.fetchOne(dbc, key: "m\(seq)")?.listenedBy ?? []
        }
    }

    func testListenerCollectsOnceOnTheMessage() async throws {
        let db = try AppDatabase.openInMemory()
        try await insertNote(db, seq: 1, outgoing: true)
        try await db.write { dbc in
            XCTAssertTrue(try SyncEngine.applyListened(dbc, chatId: "c1", targetSeq: 1, userId: "peer"))
            XCTAssertTrue(try SyncEngine.applyListened(dbc, chatId: "c1", targetSeq: 1, userId: "peer"))
            XCTAssertTrue(try SyncEngine.applyListened(dbc, chatId: "c1", targetSeq: 1, userId: "other"))
        }
        let who = try await listeners(db, seq: 1)
        XCTAssertEqual(who, ["peer", "other"])
    }

    func testListenedBeforeItsTargetWaitsAndLands() async throws {
        let db = try AppDatabase.openInMemory()
        var event = ContentPayload(kind: "listened")
        event.targetSeq = 5
        try await db.write { dbc in
            // the event arrives first: nothing to land on yet
            XCTAssertFalse(try SyncEngine.applyListened(dbc, chatId: "c1", targetSeq: 5, userId: "peer"))
            try SyncEngine.bufferPendingApply(dbc, chatId: "c1", targetSeq: 5, kind: "listened",
                                              fromUserId: "peer",
                                              payload: SyncEngine.payloadJSON(event), seq: 6)
        }
        try await insertNote(db, seq: 5, outgoing: true)
        try await db.write { dbc in
            try SyncEngine.applyBuffered(dbc, chatId: "c1", seq: 5)
        }
        let who = try await listeners(db, seq: 5)
        XCTAssertEqual(who, ["peer"])
    }

    func testListenedIsAServiceKind() {
        XCTAssertTrue(SyncEngine.serviceKinds.contains("listened"))
        XCTAssertTrue(SyncEngine.rowlessKinds.contains("listened"),
                      "the event leaves no feed row of its own")
        XCTAssertTrue(NotificationContentBuilder.silentKinds.contains("listened"))
    }
}
