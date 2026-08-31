import Foundation
import GRDB

/// The address-book name of a matched user: what the owner's contacts call
/// the person behind a userId. Written by contact discovery, read wherever a
/// peer is named — where a row exists it wins over the profile's self-chosen
/// display name. Local only: the mapping never leaves the device.
public struct ContactBookName: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "contactBookName"

    public var userId: String
    public var name: String

    public init(userId: String, name: String) {
        self.userId = userId
        self.name = name
    }

    /// Replaces the stored mapping with a discovery result. Discovery returns
    /// the full matched set, so the previous mapping is superseded whole — a
    /// contact deleted from the book stops renaming its user.
    public static func store(_ db: Database, names: [String: String]) throws {
        try db.execute(sql: "DELETE FROM contactBookName")
        for (userId, name) in names where !name.isEmpty {
            try ContactBookName(userId: userId, name: name).insert(db)
        }
    }

    public static func name(_ db: Database, userId: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT name FROM contactBookName WHERE userId = ?",
                            arguments: [userId])
    }

    /// The user with the book name applied over `displayName`, if one is stored.
    public static func applied(_ db: Database, to user: User) throws -> User {
        var u = user
        if let book = try name(db, userId: user.id) { u.displayName = book }
        return u
    }

    /// Book names applied over a fetched batch in one query.
    public static func applied(_ db: Database, to users: [User]) throws -> [User] {
        guard !users.isEmpty else { return users }
        let rows = try Row.fetchAll(db, sql: """
            SELECT userId, name FROM contactBookName
            WHERE userId IN (\(databaseQuestionMarks(count: users.count)))
            """, arguments: StatementArguments(users.map(\.id)))
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0["userId"] as String, $0["name"] as String) })
        guard !byId.isEmpty else { return users }
        return users.map { user in
            var u = user
            if let book = byId[user.id] { u.displayName = book }
            return u
        }
    }
}
