import XCTest
import GRDB
@testable import MsngrCore

/// Service frames, and the buffer that holds edit/reaction/deleted arriving
/// before their original. No server needed, the engine is built against an
/// address nothing listens on.
final class ServiceFrameTests: XCTestCase {
    private func makeEngine(db: DatabaseQueue) throws -> SyncEngine {
        let api = APIClient(baseURL: URL(string: "http://localhost:1")!)
        let store = try IdentityStore(db: db, masterKeyProvider: StaticMasterKey())
        let e2ee = E2EEManager(store: store, api: api, ownUserId: "me", ownDeviceId: "dev")
        return SyncEngine(db: db, api: api, e2ee: e2ee,
                          wsURL: URL(string: "ws://localhost:1/ws")!,
                          ownUserId: "me", ownDeviceId: "dev")
    }

    private func msgFrame(seq: Int, service: Bool) throws -> WSIncoming {
        let json = """
        {"t":"msg","chatId":"c1","seq":\(seq),"from":"peer","fromDevice":"d1",
        "sentAt":1,"ts":1,"body":{"v":1,"mode":"skm","c":"AA==","keyId":"k1","iteration":0,"sig":"AA=="}
        \(service ? #","service":true"# : "")}
        """
        return try JSONDecoder().decode(WSIncoming.self, from: Data(json.utf8))
    }

    /// A msg with service=true moves lastSeq/syncedSeq without growing
    /// unreadCount; the next ordinary message is counted ignoring the service seq.
    func testServiceFrameDoesNotGrowUnread() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try await db.write { dbc in
            try dbc.execute(sql: "INSERT INTO chat (id, kind, createdBy, createdAt) VALUES ('c1','group','peer',0)")
        }

        await engine.apply(try msgFrame(seq: 1, service: true))
        var row = try await db.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT lastSeq, syncedSeq, unreadCount, myReadUpTo FROM chat WHERE id = 'c1'")!
        }
        XCTAssertEqual(row["lastSeq"] as Int, 1)
        XCTAssertEqual(row["syncedSeq"] as Int, 1)
        XCTAssertEqual(row["unreadCount"] as Int, 0)
        XCTAssertEqual(row["myReadUpTo"] as Int, 1) // a fully read chat absorbs the service seq

        // an ordinary message after a service one: only it counts as unread
        await engine.apply(try msgFrame(seq: 2, service: false))
        row = try await db.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT lastSeq, unreadCount FROM chat WHERE id = 'c1'")!
        }
        XCTAssertEqual(row["lastSeq"] as Int, 2)
        XCTAssertEqual(row["unreadCount"] as Int, 1)
    }

    /// A reaction and an edit for a message not yet in the database (the
    /// original is waiting for its key) are buffered and applied once the row
    /// appears.
    func testReactionAndEditBeforeOriginalApplyAfter() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)

        var reaction = ContentPayload(kind: "reaction")
        reaction.targetSeq = 1
        reaction.emoji = "👍"
        await engine.applyContent(reaction, chatId: "c1", seq: 2,
                                  from: "peer", sentAt: 1, ts: 1)
        var edit = ContentPayload(kind: "edit")
        edit.targetSeq = 1
        edit.text = "corrected"
        await engine.applyContent(edit, chatId: "c1", seq: 3,
                                  from: "peer", sentAt: 1, ts: 1)

        let buffered = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM pendingApply WHERE targetSeq = 1")!
        }
        XCTAssertEqual(buffered, 2)

        // the original decrypted and was inserted: the buffer is applied and cleared
        var original = ContentPayload(kind: "text")
        original.text = "the original"
        await engine.applyContent(original, chatId: "c1", seq: 1,
                                  from: "peer", sentAt: 1, ts: 1)

        let row = try await db.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT text, edited, reactions FROM message WHERE chatId = 'c1' AND seq = 1")!
        }
        XCTAssertEqual(row["text"] as String, "corrected")
        XCTAssertEqual(row["edited"] as Bool, true)
        let reactions = try JSONDecoder().decode([String: [String]].self,
                                                 from: Data((row["reactions"] as String).utf8))
        XCTAssertEqual(reactions["👍"], ["peer"])
        let left = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM pendingApply")!
        }
        XCTAssertEqual(left, 0)
    }

    /// A reaction to our own message placed before the ack: while the target has no
    /// seq there is nothing to send, otherwise the peer would receive a reference
    /// they can never resolve.
    func testReactionToUnackedTargetResolvesAtSendTime() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try await db.write { dbc in
            try dbc.execute(sql: "INSERT INTO chat (id, kind, createdBy, createdAt) VALUES ('c1','direct','me',0)")
            // our own message, the ack has not arrived: no seq yet, the id is local
            try dbc.execute(sql: """
                INSERT INTO message (id, chatId, clientMsgId, fromUserId, sentAt, kind, status, isOutgoing)
                VALUES ('local-1','c1','local-1','me',1,'text',0,1)
                """)
        }
        var reaction = ContentPayload(kind: "reaction")
        reaction.targetLocalId = "local-1"
        reaction.emoji = "👍"

        do {
            _ = try await engine.resolveTarget(reaction, chatId: "c1")
            XCTFail("a reaction must not go out with a local id")
        } catch let e as SyncEngine.TargetNotAcked {
            XCTAssertFalse(e.gone, "the target may still go out: wait for the ack instead of dropping it")
        }

        // the ack arrived, the target is substituted with its seq
        let ack = try JSONDecoder().decode(WSIncoming.self, from: Data("""
        {"t":"sent","chatId":"c1","clientMsgId":"local-1","seq":1,"ts":2}
        """.utf8))
        await engine.apply(ack)
        let resolved = try await engine.resolveTarget(reaction, chatId: "c1")
        XCTAssertEqual(resolved.targetSeq, 1)
        XCTAssertNil(resolved.targetLocalId)
    }

    /// A target from the peer already has a seq, so it resolves at once. A target
    /// that never went out: the service frame is dropped.
    func testTargetFromPeerPassesThroughAndFailedTargetIsDropped() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try await db.write { dbc in
            try dbc.execute(sql: "INSERT INTO chat (id, kind, createdBy, createdAt) VALUES ('c1','direct','me',0)")
            try dbc.execute(sql: """
                INSERT INTO message (id, chatId, seq, fromUserId, sentAt, kind, status, isOutgoing)
                VALUES ('srv-9','c1',9,'peer',1,'text',1,0)
                """)
            try dbc.execute(sql: """
                INSERT INTO message (id, chatId, clientMsgId, fromUserId, sentAt, kind, status, isOutgoing)
                VALUES ('local-2','c1','local-2','me',1,'text',-1,1)
                """)
        }
        var edit = ContentPayload(kind: "edit")
        edit.targetLocalId = "srv-9"
        edit.text = "corrected"
        let fromPeer = try await engine.resolveTarget(edit, chatId: "c1")
        XCTAssertEqual(fromPeer.targetSeq, 9)

        edit.targetLocalId = "local-2"
        do {
            _ = try await engine.resolveTarget(edit, chatId: "c1")
            XCTFail("an edit of a message that never went out must not be sent")
        } catch let e as SyncEngine.TargetNotAcked {
            XCTAssertTrue(e.gone)
        }
    }

    /// The ack releases the service frames that waited for their target's seq.
    func testAckReleasesWaitingOutboxRows() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try await db.write { dbc in
            try dbc.execute(sql: "INSERT INTO chat (id, kind, createdBy, createdAt) VALUES ('c1','direct','me',0)")
            try OutboxItem(clientMsgId: "r1", chatId: "c1", createdAt: 2,
                           payload: Data("{}".utf8), state: "waiting").save(dbc)
        }
        let ack = try JSONDecoder().decode(WSIncoming.self, from: Data("""
        {"t":"sent","chatId":"c1","clientMsgId":"local-1","seq":1,"ts":2}
        """.utf8))
        await engine.apply(ack)

        let state = try await db.read { dbc in
            try String.fetchOne(dbc, sql: "SELECT state FROM outbox WHERE clientMsgId = 'r1'")
        }
        XCTAssertEqual(state, "ready")
    }

    /// A deleted arriving before the original is buffered; a repeated deleted
    /// (sync replay) is idempotent.
    func testDeletedBeforeOriginalAndReplay() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        let deleted = try JSONDecoder().decode(WSIncoming.self, from: Data("""
        {"t":"deleted","chatId":"c1","seqs":[1],"forAll":true,"by":"peer"}
        """.utf8))

        await engine.apply(deleted)
        var original = ContentPayload(kind: "text")
        original.text = "a secret"
        await engine.applyContent(original, chatId: "c1", seq: 1,
                                  from: "peer", sentAt: 1, ts: 1)
        await engine.apply(deleted) // replay once the row exists

        let row = try await db.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT deletedForAll, text FROM message WHERE chatId = 'c1' AND seq = 1")!
        }
        XCTAssertEqual(row["deletedForAll"] as Bool, true)
        XCTAssertNil(row["text"] as String?)
    }
}
