import XCTest
import GRDB
@testable import MsngrCore

final class UpsertTests: XCTestCase {
    func testChatFrameDecodeAndUpsert() throws {
        let json = """
        {"t":"chat","chatId":"direct:A:B","event":"created","state":{"chatId":"direct:A:B",
        "kind":"direct","title":null,"avatarId":null,"description":null,"createdBy":"A",
        "createdAt":1786480986373,"members":[
        {"userId":"A","role":"member","joinedAt":1786480986373,"accepted":true},
        {"userId":"B","role":"member","joinedAt":1786480986373,"accepted":false}],
        "pinnedSeqs":[],"lastSeq":0,"readMarks":{},"deliveredMarks":{}}}
        """
        let frame = try JSONDecoder().decode(WSIncoming.self, from: Data(json.utf8))
        XCTAssertEqual(frame.t, "chat")
        let state = try XCTUnwrap(frame.state)
        XCTAssertEqual(state.members.count, 2)

        let db = try AppDatabase.openInMemory()
        try db.write { dbc in
            try SyncEngine.upsertChatState(dbc, state, ownUserId: "B", flags: nil)
        }
        let (isRequest, iAccepted) = try db.read { dbc -> (Bool, Bool) in
            let row = try Row.fetchOne(dbc, sql: "SELECT isRequest, iAccepted FROM chat WHERE id = 'direct:A:B'")!
            return (row["isRequest"], row["iAccepted"])
        }
        XCTAssertTrue(isRequest)
        XCTAssertFalse(iAccepted)
    }

    /// A snapshot taken before /accept reached the server must not roll back the
    /// local accept, or an accepted chat would hide its history again.
    func testAcceptSurvivesStaleSnapshot() throws {
        let state = ChatStateDTO(
            chatId: "direct:A:B", kind: "direct", title: nil, avatarId: nil, description: nil,
            sendPolicy: nil, invitePolicy: nil, createdBy: "A", createdAt: 1, members: [
                .init(userId: "A", role: "member", joinedAt: 1, accepted: true),
                .init(userId: "B", role: "member", joinedAt: 1, accepted: false),
            ],
            pinnedSeqs: nil, lastSeq: 3, readMarks: [:], deliveredMarks: [:])

        let db = try AppDatabase.openInMemory()
        try db.write { dbc in
            try SyncEngine.upsertChatState(dbc, state, ownUserId: "B", flags: nil)
            try dbc.execute(sql: "UPDATE chat SET isRequest = 0, iAccepted = 1 WHERE id = 'direct:A:B'")
            // the same, now stale, snapshot arrives once more
            try SyncEngine.upsertChatState(dbc, state, ownUserId: "B", flags: nil)
        }
        let (isRequest, iAccepted) = try db.read { dbc -> (Bool, Bool) in
            let row = try Row.fetchOne(dbc, sql: "SELECT isRequest, iAccepted FROM chat WHERE id = 'direct:A:B'")!
            return (row["isRequest"], row["iAccepted"])
        }
        XCTAssertFalse(isRequest)
        XCTAssertTrue(iAccepted)
    }
}
