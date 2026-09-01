import XCTest
import GRDB
@testable import MsngrCore

/// System lines in the feed. One state is said once: an identity change stops
/// every message the outbox holds for that peer, and a line per stopped message
/// is how a chat came to carry six hundred identical ones.
final class SystemLineTests: XCTestCase {
    private func chat(_ db: DatabaseQueue) async throws {
        try await db.write { dbc in
            try dbc.execute(sql: """
                INSERT INTO chat (id, kind, createdBy, createdAt) VALUES ('c1','direct','peer',0)
                """)
        }
    }

    func testTheSameLineIsNotRepeated() async throws {
        let db = try AppDatabase.openInMemory()
        try await chat(db)
        try await db.write { dbc in
            XCTAssertTrue(try SyncEngine.insertSystemLine(dbc, chatId: "c1",
                                                          text: "identity_changed:peer"))
            for _ in 0..<50 {
                XCTAssertFalse(try SyncEngine.insertSystemLine(dbc, chatId: "c1",
                                                               text: "identity_changed:peer"))
            }
        }
        let count = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId='c1'")!
        }
        XCTAssertEqual(count, 1)
    }

    /// A different line still lands, and the first one may be said again once
    /// something else has been said in between: it is a new turn of the state.
    func testADifferentLineLandsAndTheStateCanReturn() async throws {
        let db = try AppDatabase.openInMemory()
        try await chat(db)
        try await db.write { dbc in
            try SyncEngine.insertSystemLine(dbc, chatId: "c1", text: "identity_changed:peer")
            XCTAssertTrue(try SyncEngine.insertSystemLine(dbc, chatId: "c1", text: "identity_ok:peer"))
            XCTAssertTrue(try SyncEngine.insertSystemLine(dbc, chatId: "c1",
                                                          text: "identity_changed:peer"))
        }
        let count = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId='c1'")!
        }
        XCTAssertEqual(count, 3)
    }

    func testAnotherChatIsNotAffected() async throws {
        let db = try AppDatabase.openInMemory()
        try await chat(db)
        try await db.write { dbc in
            try dbc.execute(sql: """
                INSERT INTO chat (id, kind, createdBy, createdAt) VALUES ('c2','direct','peer',0)
                """)
            try SyncEngine.insertSystemLine(dbc, chatId: "c1", text: "identity_changed:peer")
            XCTAssertTrue(try SyncEngine.insertSystemLine(dbc, chatId: "c2",
                                                          text: "identity_changed:peer"))
        }
    }
}
