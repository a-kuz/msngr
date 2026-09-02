import XCTest
import GRDB
@testable import MsngrCore

/// A mute is a local flag plus a queued action, and a chat snapshot fetched
/// before that action landed does not put the previous flag back.
final class MuteActionTests: XCTestCase {
    private func makeEngine(db: DatabaseQueue) throws -> SyncEngine {
        let api = APIClient(baseURL: URL(string: "http://localhost:1")!)
        let store = try IdentityStore(db: db, masterKeyProvider: StaticMasterKey())
        let e2ee = E2EEManager(store: store, api: api, ownUserId: "me", ownDeviceId: "dev")
        return SyncEngine(db: db, api: api, e2ee: e2ee,
                          wsURL: URL(string: "ws://localhost:1/ws")!,
                          ownUserId: "me", ownDeviceId: "dev")
    }

    private static func state(_ chatId: String) -> ChatStateDTO {
        ChatStateDTO(chatId: chatId, kind: "direct", title: nil, avatarId: nil, description: nil,
                     sendPolicy: nil, invitePolicy: nil, createdBy: "me", createdAt: 0,
                     plaintext: nil,
                     members: [.init(userId: "me", role: "member", joinedAt: 0, accepted: true),
                               .init(userId: "peer", role: "member", joinedAt: 0, accepted: true)],
                     pinnedSeqs: nil, lastSeq: 0, readMarks: [:], deliveredMarks: [:])
    }

    private func muted(_ db: DatabaseQueue, _ chatId: String) throws -> (Bool, Double?) {
        try db.read { dbc in
            let row = try Row.fetchOne(dbc, sql: "SELECT muted, mutedUntil FROM chat WHERE id = ?",
                                       arguments: [chatId])!
            return (row["muted"], row["mutedUntil"])
        }
    }

    func testMuteWritesTheRowAndQueuesOneActionPerChat() async throws {
        let db = try AppDatabase.openInMemory()
        try await db.write { dbc in
            try Chat(id: "c1", kind: .direct, title: nil, createdBy: "peer", createdAt: 0,
                     lastSeq: 1, syncedSeq: 1, lastActivityAt: 0).save(dbc)
        }
        let engine = try makeEngine(db: db)

        try await engine.setMuted(chatId: "c1", muted: true, until: 100)
        XCTAssertEqual(try muted(db, "c1").0, true)
        XCTAssertEqual(try muted(db, "c1").1, 100)

        // the second decision replaces the first in the queue instead of
        // lining up behind it
        try await engine.setMuted(chatId: "c1", muted: false)
        XCTAssertEqual(try muted(db, "c1").0, false)
        let actions = try await db.read { dbc in
            try Row.fetchAll(dbc, sql: "SELECT id, payload FROM pendingAction WHERE type = 'mute'")
        }
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?["id"] as String?, "mute:c1")
        XCTAssertTrue((actions.first?["payload"] as String? ?? "").contains("\"muted\":false"))
    }

    func testSnapshotKeepsAMuteTheServerHasNotConfirmed() async throws {
        let db = try AppDatabase.openInMemory()
        try await db.write { dbc in
            try Chat(id: "c1", kind: .direct, title: nil, createdBy: "peer", createdAt: 0,
                     lastSeq: 1, syncedSeq: 1, lastActivityAt: 0).save(dbc)
        }
        let engine = try makeEngine(db: db)
        try await engine.setMuted(chatId: "c1", muted: true)

        // a snapshot built before the request landed still says "not muted"
        try await db.write { dbc in
            try SyncEngine.upsertChatState(
                dbc, Self.state("c1"), ownUserId: "me",
                flags: SyncEngine.ChatFlags(pinned: false, muted: false, mutedUntil: nil, archived: false))
        }
        XCTAssertEqual(try muted(db, "c1").0, true)

        // once the action has left the queue the server's flag is the truth
        try await db.write { dbc in
            try dbc.execute(sql: "DELETE FROM pendingAction WHERE type = 'mute'")
            try SyncEngine.upsertChatState(
                dbc, Self.state("c1"), ownUserId: "me",
                flags: SyncEngine.ChatFlags(pinned: false, muted: false, mutedUntil: nil, archived: false))
        }
        XCTAssertEqual(try muted(db, "c1").0, false)
    }
}
