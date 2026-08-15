import XCTest
import GRDB
@testable import MsngrCore

/// Three places where this build can meet something newer than itself: the
/// server it connects to, an envelope it is handed, and the database it opens.
/// None of them may end in silence, a crash or a corrupted file.
final class VersioningTests: XCTestCase {

    // MARK: - Protocol version in the handshake

    func testUpgradeCarriesProtocolVersion() throws {
        let url = MsngrProtocol.versioned(URL(string: "ws://host/ws?token=t1")!)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "v" }?.value, String(MsngrProtocol.version))
        XCTAssertEqual(items.first { $0.name == "token" }?.value, "t1")
    }

    /// The version the server sees is the one this build speaks, whatever the
    /// caller put on the URL.
    func testUpgradeReplacesAForeignVersion() throws {
        let url = MsngrProtocol.versioned(URL(string: "ws://host/ws?token=t1&v=0")!)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.filter { $0.name == "v" }.map(\.value), [String(MsngrProtocol.version)])
    }

    /// The server refuses the very first upgrade, which happens while the
    /// engine starts and before the app subscribes. A refusal that arrived
    /// first must still reach the screen.
    func testProtocolRefusalReachesALateSubscriber() async throws {
        let engine = try makeEngine(db: try AppDatabase.openInMemory())
        engine.protocolOutdatedStream.send(())

        let delivered = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in engine.protocolOutdatedStream.subscribe() { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertTrue(delivered, "the refusal was dropped: the app keeps showing a connecting state")
    }

    // MARK: - Envelope format version

    private func makeEngine(db: DatabaseQueue) throws -> SyncEngine {
        let api = APIClient(baseURL: URL(string: "http://localhost:1")!)
        let store = try IdentityStore(db: db, masterKeyProvider: StaticMasterKey())
        let e2ee = E2EEManager(store: store, api: api, ownUserId: "me", ownDeviceId: "dev")
        return SyncEngine(db: db, api: api, e2ee: e2ee,
                          wsURL: URL(string: "ws://localhost:1/ws")!,
                          ownUserId: "me", ownDeviceId: "dev")
    }

    private func makeDirectChat(_ db: DatabaseQueue) async throws {
        try await db.write { dbc in
            try dbc.execute(sql: "INSERT INTO chat (id, kind, createdBy, createdAt) VALUES ('c1','direct','peer',0)")
            try dbc.execute(sql: "INSERT INTO member (chatId, userId, role, joinedAt) VALUES ('c1','me','member',0)")
            try dbc.execute(sql: "INSERT INTO member (chatId, userId, role, joinedAt) VALUES ('c1','peer','member',0)")
        }
    }

    /// An envelope written in a newer format is not guessed at: it is stored as
    /// it arrived, the seq is marked unreadable, and the sender is left alone —
    /// a fresh copy would come back in the same format.
    func testEnvelopeAheadOfBuildIsKeptAndSenderIsNotAsked() async throws {
        let db = try AppDatabase.openInMemory()
        try await makeDirectChat(db)
        let engine = try makeEngine(db: db)
        let json = """
        {"t":"msg","chatId":"c1","seq":1,"msgId":"m1","from":"peer","fromDevice":"d1",
        "sentAt":1,"ts":1,"body":{"v":\(MsngrProtocol.envelopeVersion + 1),"mode":"pw","msgs":{}}}
        """

        await engine.apply(try JSONDecoder().decode(WSIncoming.self, from: Data(json.utf8)))

        let pending = try await db.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT * FROM pendingDecrypt WHERE chatId = 'c1' AND msgId = 'm1'")
        }
        let row = try XCTUnwrap(pending, "envelope dropped: a newer build would have nothing to open")
        XCTAssertFalse((row["body"] as Data).isEmpty)
        XCTAssertEqual(row["reason"] as String?, MessageRepair.envelopeAheadReason)
        XCTAssertEqual(row["repairAttempts"] as Int, 0)

        let gap = try await db.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT * FROM historyGap WHERE chatId = 'c1' AND seq = 1")
        }
        XCTAssertEqual(try XCTUnwrap(gap)["reason"] as String?, MessageRepair.envelopeAheadReason)

        let outbox = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM outbox") ?? 0
        }
        XCTAssertEqual(outbox, 0, "asked the sender for a copy this build could not read either")
    }

    /// An envelope at this build's format goes down the normal path: with no
    /// box addressed to this device the direct chat records the missing
    /// ciphertext, which is a repairable defect, not a version refusal.
    func testEnvelopeAtBuildVersionIsDecrypted() async throws {
        let db = try AppDatabase.openInMemory()
        try await makeDirectChat(db)
        let engine = try makeEngine(db: db)
        let json = """
        {"t":"msg","chatId":"c1","seq":1,"msgId":"m1","from":"peer","fromDevice":"d1",
        "sentAt":1,"ts":1,"body":{"v":\(MsngrProtocol.envelopeVersion),"mode":"pw","msgs":{}}}
        """

        await engine.apply(try JSONDecoder().decode(WSIncoming.self, from: Data(json.utf8)))

        let reason = try await db.read { dbc in
            try String.fetchOne(dbc, sql: "SELECT reason FROM pendingDecrypt WHERE chatId = 'c1' AND msgId = 'm1'")
        }
        XCTAssertEqual(reason, "no_ciphertext")
    }

    /// Repair spends attempts on failures a fresh copy can fix. This one it
    /// cannot, so the counter stays whole for the envelopes it can.
    func testEnvelopeAheadIsNeverRepaired() {
        let now = Date().timeIntervalSince1970
        XCTAssertFalse(MessageRepair.repairDue(reason: MessageRepair.envelopeAheadReason,
                                               firstSeenAt: now - MessageRepair.repairGrace * 10,
                                               repairAttempts: 0, repairAskedAt: 0, now: now))
        XCTAssertTrue(MessageRepair.repairDue(reason: "bad_box",
                                              firstSeenAt: now - MessageRepair.repairGrace * 10,
                                              repairAttempts: 0, repairAskedAt: 0, now: now))
    }

    /// With no attempt spent the envelope never ages out: it is the only copy
    /// this device holds, and a build that knows the format opens it.
    func testEnvelopeAheadIsNotDroppedByAge() {
        let now = Date().timeIntervalSince1970
        XCTAssertFalse(MessageRepair.expired(firstSeenAt: now - MessageRepair.envelopeTTL * 2,
                                             repairAttempts: 0, now: now))
    }

    // MARK: - Database schema version

    private var tmp: URL!
    private var location: StorageLocation!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("versioning-\(UUID().uuidString)")
        location = StorageLocation(root: tmp)
        try AppContainer.prepare(location, fileManager: fm)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tmp)
    }

    /// A database migrated by a build that knows one more migration than this one.
    private func seedStorageFromNewerBuild() throws {
        let db = try AppDatabase.open(at: location.databaseURL)
        try db.write { dbc in
            try dbc.execute(sql: "INSERT INTO user (id, username, displayName) VALUES ('alice','alice','Alice')")
            try dbc.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v99-fromANewerBuild')")
        }
        try StorageOwnership.stamp(db, userId: "alice")
        try db.close()
    }

    func testStorageAheadOfBuildIsNotOpened() throws {
        try seedStorageFromNewerBuild()

        XCTAssertThrowsError(try AppDatabase.open(at: location.databaseURL)) { error in
            guard case AppDatabaseError.schemaFromNewerVersion(let applied) = error else {
                return XCTFail("expected a schema version refusal, got \(error)")
            }
            XCTAssertEqual(applied, ["v99-fromANewerBuild"])
        }
    }

    func testStorageAheadOfBuildIsReportedAsSuch() throws {
        try seedStorageFromNewerBuild()

        XCTAssertEqual(StorageOwnership.owner(at: location.databaseURL, fileManager: fm), .schemaAhead)
        XCTAssertEqual(StorageOwnership.decision(owner: .schemaAhead, expectedUserId: "alice"), .startOver)
    }

    /// The refusal leaves the file alone: a newer build still reads it, and the
    /// clean start is the user's call.
    func testStorageAheadSurvivesTheRefusal() throws {
        try seedStorageFromNewerBuild()

        XCTAssertThrowsError(try StorageOwnership.openOwned(at: location, expectedUserId: "alice",
                                                            fileManager: fm))

        let queue = try DatabaseQueue(path: location.databaseURL.path)
        defer { try? queue.close() }
        let ids = try queue.read { dbc in try String.fetchAll(dbc, sql: "SELECT id FROM user") }
        XCTAssertEqual(ids, ["alice"])
    }

    /// Registration starts from empty storage whatever wrote it, so this is the
    /// one path out of a database ahead of the build.
    func testRegistrationStartsOverOnStorageAhead() throws {
        try seedStorageFromNewerBuild()

        let db = try StorageOwnership.openOwned(at: location, expectedUserId: nil, fileManager: fm)
        defer { try? db.close() }
        let ids = try db.read { dbc in try String.fetchAll(dbc, sql: "SELECT id FROM user") }
        XCTAssertEqual(ids, [])
    }

    /// A file this build can migrate forward is not mistaken for a newer one.
    func testStorageOfThisBuildOpens() throws {
        let db = try AppDatabase.open(at: location.databaseURL)
        try db.close()

        XCTAssertNotEqual(StorageOwnership.owner(at: location.databaseURL, fileManager: fm), .schemaAhead)
        XCTAssertNoThrow(try AppDatabase.open(at: location.databaseURL).close())
    }
}
