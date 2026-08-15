import XCTest
import GRDB
@testable import MsngrCore

final class StorageOwnershipTests: XCTestCase {
    private var tmp: URL!
    private var location: StorageLocation!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("storage-ownership-\(UUID().uuidString)")
        location = StorageLocation(root: tmp)
        try AppContainer.prepare(location, fileManager: fm)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tmp)
    }

    /// Database with one user row and, optionally, an owner marker.
    private func seed(owner: String?) throws {
        let db = try AppDatabase.open(at: location.databaseURL)
        try db.write { dbc in
            try dbc.execute(sql: "INSERT INTO user (id, username, displayName) VALUES ('alice','alice','Alice')")
        }
        if let owner { try StorageOwnership.stamp(db, userId: owner) }
        try db.close()
    }

    private func storedUserIds() throws -> [String] {
        let db = try AppDatabase.open(at: location.databaseURL)
        defer { try? db.close() }
        return try db.read { dbc in try String.fetchAll(dbc, sql: "SELECT id FROM user ORDER BY id") }
    }

    // MARK: - Decision

    func testMatchingMarkerKeepsStorage() {
        XCTAssertEqual(StorageOwnership.decision(owner: .user("alice"), expectedUserId: "alice"), .keep)
    }

    func testForeignMarkerWipesStorage() {
        XCTAssertEqual(StorageOwnership.decision(owner: .user("bob"), expectedUserId: "alice"), .wipe)
    }

    /// Database left by a build that did not write the marker: the session names
    /// its owner, so the storage is adopted rather than thrown away.
    func testMissingMarkerAdoptsStorage() {
        XCTAssertEqual(StorageOwnership.decision(owner: .unmarked, expectedUserId: "alice"), .adopt)
    }

    func testRegistrationAlwaysWipes() {
        for owner: StorageOwnership.Owner in [.none, .unmarked, .unreadable, .user("alice")] {
            XCTAssertEqual(StorageOwnership.decision(owner: owner, expectedUserId: nil), .wipe,
                           "registration must not inherit \(owner)")
        }
    }

    func testEmptyLocationIsKeptForKnownAccount() {
        XCTAssertEqual(StorageOwnership.decision(owner: .none, expectedUserId: "alice"), .keep)
    }

    /// On iOS the container is unreadable until the first unlock; a launch in
    /// that state must fail on open instead of destroying the account's data.
    func testUnreadableDatabaseIsKeptForKnownAccount() {
        XCTAssertEqual(StorageOwnership.decision(owner: .unreadable, expectedUserId: "alice"), .keep)
    }

    // MARK: - Reading the marker

    func testOwnerOfEmptyLocation() {
        XCTAssertEqual(StorageOwnership.owner(at: location.databaseURL, fileManager: fm), .none)
    }

    func testOwnerOfStampedDatabase() throws {
        try seed(owner: "alice")
        XCTAssertEqual(StorageOwnership.owner(at: location.databaseURL, fileManager: fm), .user("alice"))
    }

    func testOwnerOfDatabaseWithoutMarker() throws {
        try seed(owner: nil)
        XCTAssertEqual(StorageOwnership.owner(at: location.databaseURL, fileManager: fm), .unmarked)
    }

    func testOwnerOfBrokenDatabase() throws {
        try Data("not a database".utf8).write(to: location.databaseURL)
        XCTAssertEqual(StorageOwnership.owner(at: location.databaseURL, fileManager: fm), .unreadable)
    }

    // MARK: - Opening

    /// The identity keys of a registration are generated into the database that
    /// is opened here, so a wipe that runs after the open would destroy them.
    func testWipeRunsBeforeOpen() throws {
        try seed(owner: "alice")
        var order: [String] = []

        let db = try StorageOwnership.openOwned(
            at: location, expectedUserId: nil, fileManager: fm,
            wipe: { AppContainer.wipe($0, fileManager: self.fm); order.append("wipe") },
            open: { url in order.append("open"); return try AppDatabase.open(at: url) })
        try db.close()

        XCTAssertEqual(order, ["wipe", "open"])
    }

    func testForeignStorageIsEmptyAfterOpen() throws {
        try seed(owner: "alice")
        let db = try StorageOwnership.openOwned(at: location, expectedUserId: "bob", fileManager: fm)
        try db.close()

        XCTAssertEqual(try storedUserIds(), [])
        XCTAssertEqual(StorageOwnership.owner(at: location.databaseURL, fileManager: fm), .unmarked)
    }

    func testOwnStorageSurvivesOpen() throws {
        try seed(owner: "alice")
        let db = try StorageOwnership.openOwned(at: location, expectedUserId: "alice", fileManager: fm)
        try db.close()

        XCTAssertEqual(try storedUserIds(), ["alice"])
    }

    func testStampMakesStorageOwned() throws {
        let db = try AppDatabase.open(at: location.databaseURL)
        try StorageOwnership.stamp(db, userId: "alice")
        try StorageOwnership.stamp(db, userId: "alice")
        try db.close()

        XCTAssertEqual(StorageOwnership.owner(at: location.databaseURL, fileManager: fm), .user("alice"))
    }
}
