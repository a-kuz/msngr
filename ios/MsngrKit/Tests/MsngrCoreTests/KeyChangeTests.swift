import XCTest
import GRDB
@testable import MsngrCore

/// Смена identity-ключа в группе. Отправку блокирует ключ любого участника,
/// поэтому и принимается она по всему составу, а не по одному собеседнику.
final class KeyChangeTests: XCTestCase {
    private func makeEngine(db: DatabaseQueue) throws -> (SyncEngine, IdentityStore) {
        let api = APIClient(baseURL: URL(string: "http://localhost:1")!)
        let store = try IdentityStore(db: db, masterKeyProvider: StaticMasterKey())
        let e2ee = E2EEManager(store: store, api: api, ownUserId: "me", ownDeviceId: "dev")
        return (SyncEngine(db: db, api: api, e2ee: e2ee,
                           wsURL: URL(string: "ws://localhost:1/ws")!,
                           ownUserId: "me", ownDeviceId: "dev"), store)
    }

    /// Ключ сменился у участника группы, который не «собеседник»: принятие
    /// снимает ожидание с него и возвращает заблокированную отправку в очередь.
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
        // боб пришёл с новым ключом — TOFU ставит его в ожидание
        _ = try store.checkTrust(userId: "bob", identitySigning: "k1")
        guard case .changed = try store.checkTrust(userId: "bob", identitySigning: "k2") else {
            return XCTFail("смена ключа должна распознаваться как changed")
        }
        // участник, который не менял ключ, принятием не затрагивается
        _ = try store.checkTrust(userId: "alice", identitySigning: "ka")

        await engine.acceptKeyChange(chatId: "g1")

        let (pending, current, outbox) = try await db.read { dbc in
            (try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM trustedIdentity WHERE changedPending IS NOT NULL")!,
             try String.fetchOne(dbc, sql: "SELECT identitySigning FROM trustedIdentity WHERE userId = 'bob'")!,
             try String.fetchOne(dbc, sql: "SELECT state FROM outbox WHERE clientMsgId = 'c1'")!)
        }
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(current, "k2", "принятый ключ становится доверенным")
        XCTAssertEqual(outbox, "ready", "заблокированная отправка возвращается в очередь")
    }

    /// Смена ключа у постороннего пользователя чат не разблокирует: принятие
    /// идёт по составу, а не по всей таблице доверия.
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
