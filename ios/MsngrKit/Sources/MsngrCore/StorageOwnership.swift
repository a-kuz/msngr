import Foundation
import GRDB

/// Binds the local storage to one account.
///
/// The database lives in the app group container and outlives the account: it
/// survives a lost session file, a reinstall of the session and a fresh
/// registration. Without an owner check a newly registered account opens the
/// previous personality's chats, and its reactions land on top of user ids that
/// are no longer members, so reaction counters exceed the number of participants.
///
/// The marker is a `kv` row written once the account is known. Everything that
/// opens the storage first asks who owns it and wipes the location when the
/// answer is anybody else.
public enum StorageOwnership {
    /// `kv` key holding the user id the storage belongs to.
    public static let markerKey = "ownUserId"

    /// Who the database on disk belongs to.
    public enum Owner: Sendable, Equatable {
        /// No database file in the location.
        case none
        /// Database exists but cannot be opened or read.
        case unreadable
        /// Database without an owner marker.
        case unmarked
        case user(String)
    }

    public enum Decision: Sendable, Equatable {
        case keep
        case wipe
    }

    /// Whether the storage may be reused as is.
    ///
    /// `expectedUserId` is the account about to open it, `nil` while
    /// registering: a brand-new account never inherits local data, so the
    /// location is always cleared for it.
    ///
    /// An unreadable database is kept for a known account: on iOS the container
    /// is unreadable until the first unlock, and a launch in that state must
    /// fail loudly instead of destroying the account's data.
    public static func decision(owner: Owner, expectedUserId: String?) -> Decision {
        guard let expectedUserId else { return .wipe }
        switch owner {
        case .none, .unreadable:
            return .keep
        case .unmarked:
            return .wipe
        case .user(let id):
            return id == expectedUserId ? .keep : .wipe
        }
    }

    /// Reads the owner marker without creating or migrating the database.
    public static func owner(at databaseURL: URL, fileManager: FileManager = .default) -> Owner {
        guard fileManager.fileExists(atPath: databaseURL.path) else { return .none }
        do {
            let queue = try DatabaseQueue(path: databaseURL.path)
            defer { try? queue.close() }
            let marker: String? = try queue.read { db in
                guard try db.tableExists("kv") else { return nil }
                return try String.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?", arguments: [markerKey])
            }
            guard let marker, !marker.isEmpty else { return .unmarked }
            return .user(marker)
        } catch {
            MsngrLog.storage.error("cannot read storage owner at \(databaseURL.path): \(error)")
            return .unreadable
        }
    }

    /// Opens the database, wiping the location first when it belongs to another
    /// account. The wipe has to precede the open: registration generates the
    /// device identity into this very database, and clearing the location
    /// afterwards would destroy the fresh keys.
    public static func openOwned(at location: StorageLocation,
                                 expectedUserId: String?,
                                 fileManager: FileManager = .default,
                                 wipe: (StorageLocation) -> Void = { AppContainer.wipe($0) },
                                 open: (URL) throws -> DatabaseQueue = { try AppDatabase.open(at: $0) })
        throws -> DatabaseQueue {
        let decision = decision(owner: owner(at: location.databaseURL, fileManager: fileManager),
                                expectedUserId: expectedUserId)
        if decision == .wipe { wipe(location) }
        return try open(location.databaseURL)
    }

    /// Marks the storage as owned by `userId`.
    public static func stamp(_ db: DatabaseQueue, userId: String) throws {
        try db.write { dbc in
            try KVRow(key: markerKey, value: userId).upsert(dbc)
        }
    }
}
