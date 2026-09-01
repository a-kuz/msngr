import XCTest
import GRDB
@testable import MsngrCore

/// The owner's address-book name for a matched user: stored by discovery,
/// applied over the profile name wherever the person is shown.
final class ContactBookNameTests: XCTestCase {
    private func user(_ id: String, name: String) -> User {
        User(id: id, username: id, displayName: name)
    }

    func testBookNameWinsOverProfileName() throws {
        let db = try AppDatabase.openInMemory()
        try db.write { dbc in
            try ContactBookName.store(dbc, names: ["u1": "Мама"])
            let applied = try ContactBookName.applied(dbc, to: self.user("u1", name: "Anna K"))
            XCTAssertEqual(applied.displayName, "Мама")
        }
    }

    func testUnmatchedUserKeepsProfileName() throws {
        let db = try AppDatabase.openInMemory()
        try db.write { dbc in
            try ContactBookName.store(dbc, names: ["u1": "Мама"])
            let applied = try ContactBookName.applied(dbc, to: self.user("u2", name: "Bob"))
            XCTAssertEqual(applied.displayName, "Bob")
        }
    }

    func testBatchAppliesOnlyStoredNames() throws {
        let db = try AppDatabase.openInMemory()
        try db.write { dbc in
            try ContactBookName.store(dbc, names: ["u1": "Мама", "u3": "Шеф"])
            let out = try ContactBookName.applied(dbc, to: [
                self.user("u1", name: "Anna K"),
                self.user("u2", name: "Bob"),
                self.user("u3", name: "Carl"),
            ])
            XCTAssertEqual(out.map(\.displayName), ["Мама", "Bob", "Шеф"])
        }
    }

    /// A new discovery result supersedes the mapping whole: a contact deleted
    /// from the book stops renaming its user.
    func testNextDiscoveryReplacesTheMapping() throws {
        let db = try AppDatabase.openInMemory()
        try db.write { dbc in
            try ContactBookName.store(dbc, names: ["u1": "Мама", "u2": "Bob (work)"])
            try ContactBookName.store(dbc, names: ["u2": "Bob"])
            XCTAssertNil(try ContactBookName.name(dbc, userId: "u1"))
            XCTAssertEqual(try ContactBookName.name(dbc, userId: "u2"), "Bob")
        }
    }

    func testEmptyBookNameIsNotStored() throws {
        let db = try AppDatabase.openInMemory()
        try db.write { dbc in
            try ContactBookName.store(dbc, names: ["u1": ""])
            XCTAssertNil(try ContactBookName.name(dbc, userId: "u1"))
        }
    }
}
