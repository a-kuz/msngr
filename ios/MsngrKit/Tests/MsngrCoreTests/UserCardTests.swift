import XCTest
import GRDB
@testable import MsngrCore

/// The chat frame carries name-only roster cards so a new chat shows named
/// rows at once; a row the device already holds keeps its fuller card.
final class UserCardTests: XCTestCase {
    private func card(_ id: String, name: String) throws -> APIClient.UserDTO {
        try JSONDecoder().decode(APIClient.UserDTO.self, from: Data("""
        {"id":"\(id)","username":"\(id)","display_name":"\(name)","bio":null,"avatar_id":null}
        """.utf8))
    }

    func testFrameCardNamesAnUnknownUser() throws {
        let db = try AppDatabase.openInMemory()
        let u = try card("u1", name: "Икфмц")
        try db.write { dbc in try SyncEngine.insertMissingUsers(dbc, [u]) }
        let name = try db.read { dbc in
            try String.fetchOne(dbc, sql: "SELECT displayName FROM user WHERE id = 'u1'")
        }
        XCTAssertEqual(name, "Икфмц")
    }

    func testFrameCardDoesNotClobberAFullerRow() throws {
        let db = try AppDatabase.openInMemory()
        try db.write { dbc in
            try dbc.execute(
                sql: "INSERT INTO user (id, username, displayName, bio, avatarId) VALUES (?,?,?,?,?)",
                arguments: ["u1", "u1", "Full Name", "a bio", "av-1"])
        }
        let u = try card("u1", name: "Names Only")
        try db.write { dbc in try SyncEngine.insertMissingUsers(dbc, [u]) }
        let row = try db.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT displayName, bio, avatarId FROM user WHERE id = 'u1'")
        }
        XCTAssertEqual(row?["displayName"], "Full Name")
        XCTAssertEqual(row?["bio"], "a bio")
        XCTAssertEqual(row?["avatarId"], "av-1")
    }

    func testChatFrameDecodesRosterCards() throws {
        let frame = try JSONDecoder().decode(WSIncoming.self, from: Data("""
        {"t":"chat","chatId":"c1","event":"created",
         "users":[{"id":"u1","username":"u1","display_name":"Икфмц","bio":null,"avatar_id":null}]}
        """.utf8))
        XCTAssertEqual(frame.users?.first?.display_name, "Икфмц")
    }
}
