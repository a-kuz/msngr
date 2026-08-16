import XCTest
import GRDB
import MsngrCrypto
@testable import MsngrCore

/// Состав группы, доигранный при догоне. Живой `chat`-фрейм об уходе участника
/// устройство могло не застать, поэтому решения о цепочке и о самом чате
/// принимаются по любому фрейму, который несёт состав.
final class MembershipReplayTests: XCTestCase {
    private func makeEngine(db: DatabaseQueue) throws -> (SyncEngine, E2EEManager) {
        let api = APIClient(baseURL: URL(string: "http://localhost:1")!)
        let store = try IdentityStore(db: db, masterKeyProvider: StaticMasterKey())
        let e2ee = E2EEManager(store: store, api: api, ownUserId: "me", ownDeviceId: "dev")
        let engine = SyncEngine(db: db, api: api, e2ee: e2ee,
                                wsURL: URL(string: "ws://localhost:1/ws")!,
                                ownUserId: "me", ownDeviceId: "dev")
        return (engine, e2ee)
    }

    private func chatFrame(event: String, members: [String]) throws -> WSIncoming {
        let list = members.map {
            #"{"userId":"\#($0)","role":"member","joinedAt":0,"accepted":true}"#
        }.joined(separator: ",")
        return try JSONDecoder().decode(WSIncoming.self, from: Data("""
        {"t":"chat","chatId":"g1","event":"\(event)",
         "state":{"chatId":"g1","kind":"group","title":"Team","createdBy":"me","createdAt":0,
                  "members":[\(list)],"lastSeq":0,"readMarks":{},"deliveredMarks":{}}}
        """.utf8))
    }

    /// Состав пришёл догоном (event "sync", не "members"), участника в нём нет:
    /// цепочка отправителя ротируется, иначе ушедший читал бы всё, что group
    /// напишет дальше.
    func testShrunkRosterFromCatchupRotatesSenderKey() async throws {
        let db = try AppDatabase.openInMemory()
        let (engine, e2ee) = try makeEngine(db: db)

        await engine.apply(try chatFrame(event: "created", members: ["me", "peer", "leaver"]))
        // цепочка заводится первой отправкой в чат
        try e2ee.store.saveSenderKeyOut(chatId: "g1", state: SenderKeyState(),
                                        distributedTo: [], attemptedAt: [:])
        let before = try e2ee.store.loadSenderKeyOut(chatId: "g1")
        XCTAssertNotNil(before, "цепочка должна существовать до ротации")

        await engine.apply(try chatFrame(event: "sync", members: ["me", "peer"]))

        XCTAssertNil(try e2ee.store.loadSenderKeyOut(chatId: "g1"),
                     "состав уменьшился — цепочка обязана быть сброшена")
    }

    /// Тот же состав — ротации нет: догон приносит состав на каждом круге, и
    /// сброс цепочки на каждом сделал бы раздачу вечной.
    func testUnchangedRosterKeepsSenderKey() async throws {
        let db = try AppDatabase.openInMemory()
        let (engine, e2ee) = try makeEngine(db: db)

        await engine.apply(try chatFrame(event: "created", members: ["me", "peer"]))
        try e2ee.store.saveSenderKeyOut(chatId: "g1", state: SenderKeyState(),
                                        distributedTo: [], attemptedAt: [:])
        let keyId = try e2ee.store.loadSenderKeyOut(chatId: "g1")?.0.keyId

        await engine.apply(try chatFrame(event: "sync", members: ["me", "peer"]))

        XCTAssertEqual(try e2ee.store.loadSenderKeyOut(chatId: "g1")?.0.keyId, keyId)
    }

    /// "removed" без состава: чат уходит с устройства и оставляет тумбстоун —
    /// вернувшийся чат заводит курсоры с него, а не с нуля.
    func testRemovedFrameDeletesChatAndLeavesTombstone() async throws {
        let db = try AppDatabase.openInMemory()
        let (engine, _) = try makeEngine(db: db)

        await engine.apply(try chatFrame(event: "created", members: ["me", "peer"]))
        try await db.write { dbc in
            try dbc.execute(sql: """
                INSERT INTO message (id, chatId, fromUserId, sentAt, kind, status, isOutgoing)
                VALUES ('m1','g1','peer',1,'text',1,0)
                """)
            try dbc.execute(sql: "UPDATE chat SET lastSeq = 7 WHERE id = 'g1'")
        }

        let removed = try JSONDecoder().decode(WSIncoming.self, from: Data("""
        {"t":"chat","chatId":"g1","event":"removed"}
        """.utf8))
        await engine.apply(removed)

        let (chats, msgs, tombstone) = try await db.read { dbc in
            (try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM chat WHERE id = 'g1'")!,
             try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = 'g1'")!,
             try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM chatTombstone WHERE chatId = 'g1'")!)
        }
        XCTAssertEqual(chats, 0)
        XCTAssertEqual(msgs, 0)
        XCTAssertEqual(tombstone, 1)
    }
}
