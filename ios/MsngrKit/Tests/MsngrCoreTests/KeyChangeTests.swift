import XCTest
import GRDB
@testable import MsngrCore

/// An identity key change in a group. Any member's key blocks sending, so the
/// acceptance covers the whole roster rather than a single peer.
final class KeyChangeTests: XCTestCase {
    private func makeEngine(db: DatabaseQueue) throws -> (SyncEngine, IdentityStore) {
        let api = APIClient(baseURL: URL(string: "http://localhost:1")!)
        let store = try IdentityStore(db: db, masterKeyProvider: StaticMasterKey())
        let e2ee = E2EEManager(store: store, api: api, ownUserId: "me", ownDeviceId: "dev")
        return (SyncEngine(db: db, api: api, e2ee: e2ee,
                           wsURL: URL(string: "ws://localhost:1/ws")!,
                           ownUserId: "me", ownDeviceId: "dev"), store)
    }

    /// The key changed for a group member who is not "the peer": accepting clears
    /// the pending state for them and returns the blocked send to the queue.
    func testAcceptCoversEveryMemberOfTheChat() async throws {
        let db = try AppDatabase.openInMemory()
        let (engine, store) = try makeEngine(db: db)
        try await db.write { dbc in
            try dbc.execute(sql: "INSERT INTO chat (id, kind, createdBy, createdAt) VALUES ('g1','group','me',0)")
            for uid in ["me", "alice", "bob"] {
                try dbc.execute(sql: "INSERT INTO member (chatId, userId, role, joinedAt) VALUES ('g1',?,'member',0)",
                                arguments: [uid])
            }
            try OutboxItem(clientMsgId: "c1", chatId: "g1", createdAt: 1,
                           payload: Data("{}".utf8), state: "blocked").save(dbc)
        }
        // bob showed up with a new key: TOFU puts it in the pending state
        _ = try store.checkTrust(userId: "bob", identitySigning: "k1")
        guard case .changed = try store.checkTrust(userId: "bob", identitySigning: "k2") else {
            return XCTFail("a key change must be recognized as changed")
        }
        // a member whose key did not change is untouched by the acceptance
        _ = try store.checkTrust(userId: "alice", identitySigning: "ka")

        await engine.acceptKeyChange(chatId: "g1")

        let (pending, current, outbox) = try await db.read { dbc in
            (try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM trustedIdentity WHERE changedPending IS NOT NULL")!,
             try String.fetchOne(dbc, sql: "SELECT identitySigning FROM trustedIdentity WHERE userId = 'bob'")!,
             try String.fetchOne(dbc, sql: "SELECT state FROM outbox WHERE clientMsgId = 'c1'")!)
        }
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(current, "k2", "an accepted key becomes the trusted one")
        XCTAssertEqual(outbox, "ready", "a blocked send returns to the queue")
    }

    /// A key change for an outsider does not unblock the chat: acceptance runs over
    /// the roster, not over the whole trust table.
    func testAcceptLeavesOutsidersPending() async throws {
        let db = try AppDatabase.openInMemory()
        let (engine, store) = try makeEngine(db: db)
        try await db.write { dbc in
            try dbc.execute(sql: "INSERT INTO chat (id, kind, createdBy, createdAt) VALUES ('g1','group','me',0)")
            try dbc.execute(sql: "INSERT INTO member (chatId, userId, role, joinedAt) VALUES ('g1','me','member',0)")
        }
        _ = try store.checkTrust(userId: "stranger", identitySigning: "k1")
        _ = try store.checkTrust(userId: "stranger", identitySigning: "k2")

        await engine.acceptKeyChange(chatId: "g1")

        let pending = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM trustedIdentity WHERE changedPending IS NOT NULL")!
        }
        XCTAssertEqual(pending, 1)
    }
}
