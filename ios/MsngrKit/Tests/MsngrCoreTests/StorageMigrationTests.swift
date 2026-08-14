import XCTest
import GRDB
import CryptoKit
@testable import MsngrCore

final class StorageMigrationTests: XCTestCase {
    private var tmp: URL!
    private var old: StorageLocation!
    private var new: StorageLocation!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("storage-migration-\(UUID().uuidString)")
        old = StorageLocation(root: tmp.appendingPathComponent("support"))
        new = StorageLocation(root: tmp.appendingPathComponent("group"))
        try fm.createDirectory(at: old.root, withIntermediateDirectories: true)
        try fm.createDirectory(at: new.root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tmp)
    }

    /// Заполняет размещение: БД с записью, мастер-ключ, исходник офлайн-вложения.
    @discardableResult
    private func seed(_ location: StorageLocation, userId: String) throws -> Data {
        let db = try AppDatabase.open(at: location.databaseURL)
        try db.write { dbc in
            try dbc.execute(sql: "INSERT INTO user (id, username, displayName) VALUES (?,?,?)",
                            arguments: [userId, "user-\(userId)", "User \(userId)"])
        }
        try db.close()
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try key.write(to: location.masterKeyURL)
        try fm.createDirectory(at: location.pendingMediaDir, withIntermediateDirectories: true)
        try Data("outgoing".utf8).write(to: location.pendingMediaDir.appendingPathComponent("pending.bin"))
        return key
    }

    private func storedUserIds(_ location: StorageLocation) throws -> [String] {
        let db = try AppDatabase.open(at: location.databaseURL)
        defer { try? db.close() }
        return try db.read { dbc in try String.fetchAll(dbc, sql: "SELECT id FROM user ORDER BY id") }
    }

    func testMovesDatabaseAndKeyAndRemovesOriginals() throws {
        let key = try seed(old, userId: "alice")

        let outcome = try StorageMigration.run(from: old, to: new, fileManager: fm)

        guard case .migrated(let names) = outcome else { return XCTFail("ожидался перенос, получено \(outcome)") }
        XCTAssertTrue(names.contains(StorageLocation.databaseFileName))
        XCTAssertTrue(names.contains(StorageLocation.masterKeyFileName))

        XCTAssertTrue(fm.fileExists(atPath: new.databaseURL.path))
        XCTAssertTrue(fm.fileExists(atPath: new.masterKeyURL.path))
        XCTAssertTrue(fm.fileExists(atPath: new.pendingMediaDir.appendingPathComponent("pending.bin").path))
        XCTAssertEqual(try Data(contentsOf: new.masterKeyURL), key)
        XCTAssertEqual(try storedUserIds(new), ["alice"])

        XCTAssertFalse(fm.fileExists(atPath: old.databaseURL.path))
        XCTAssertFalse(fm.fileExists(atPath: old.masterKeyURL.path))
        XCTAssertFalse(fm.fileExists(atPath: old.pendingMediaDir.path))
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: new.root.path)
            .allSatisfy { !$0.hasPrefix(".migration-") }, "временный каталог переноса остался")
    }

    func testWriteAheadLogMovesWithDatabase() throws {
        // открытая в WAL база: -wal и -shm рядом с файлом БД
        let db = try AppDatabase.open(at: old.databaseURL)
        try db.write { dbc in
            try dbc.execute(sql: "INSERT INTO user (id, username, displayName) VALUES ('bob','bob','Bob')")
        }
        XCTAssertTrue(fm.fileExists(atPath: old.databaseURL.path + "-wal"))
        try Data(repeating: 7, count: 32).write(to: old.masterKeyURL)

        let outcome = try StorageMigration.run(from: old, to: new, fileManager: fm)
        try db.close()

        guard case .migrated(let names) = outcome else { return XCTFail("ожидался перенос") }
        XCTAssertTrue(names.contains(StorageLocation.databaseFileName + "-wal"))
        XCTAssertEqual(try storedUserIds(new), ["bob"])
        XCTAssertFalse(fm.fileExists(atPath: old.databaseURL.path + "-wal"))
        XCTAssertFalse(fm.fileExists(atPath: old.databaseURL.path + "-shm"))
    }

    func testSecondRunIsNoOp() throws {
        try seed(old, userId: "alice")
        _ = try StorageMigration.run(from: old, to: new, fileManager: fm)
        let keyAfterFirst = try Data(contentsOf: new.masterKeyURL)

        XCTAssertEqual(try StorageMigration.run(from: old, to: new, fileManager: fm), .notNeeded)

        XCTAssertEqual(try Data(contentsOf: new.masterKeyURL), keyAfterFirst)
        XCTAssertEqual(try storedUserIds(new), ["alice"])
    }

    func testOccupiedDestinationLeavesOldUntouched() throws {
        let oldKey = try seed(old, userId: "alice")
        let newKey = try seed(new, userId: "bob")

        XCTAssertEqual(try StorageMigration.run(from: old, to: new, fileManager: fm), .notNeeded)

        XCTAssertEqual(try storedUserIds(new), ["bob"])
        XCTAssertEqual(try Data(contentsOf: new.masterKeyURL), newKey)
        XCTAssertEqual(try storedUserIds(old), ["alice"])
        XCTAssertEqual(try Data(contentsOf: old.masterKeyURL), oldKey)
    }

    /// Перенос прервали между файлами: в новом размещении лежит ключ, БД ещё
    /// в старом. Следующий запуск доводит перенос до конца.
    func testInterruptedMigrationCompletes() throws {
        let key = try seed(old, userId: "alice")
        try fm.moveItem(at: old.masterKeyURL, to: new.masterKeyURL)

        let outcome = try StorageMigration.run(from: old, to: new, fileManager: fm)

        guard case .migrated = outcome else { return XCTFail("ожидался перенос, получено \(outcome)") }
        XCTAssertEqual(try storedUserIds(new), ["alice"])
        XCTAssertEqual(try Data(contentsOf: new.masterKeyURL), key)
        XCTAssertFalse(fm.fileExists(atPath: old.databaseURL.path))
    }

    func testEmptyOldLocationIsNoOp() throws {
        XCTAssertEqual(try StorageMigration.run(from: old, to: new, fileManager: fm), .notNeeded)
        XCTAssertFalse(fm.fileExists(atPath: new.databaseURL.path))
    }

    func testSameRootIsNoOp() throws {
        try seed(old, userId: "alice")
        XCTAssertEqual(try StorageMigration.run(from: old, to: old, fileManager: fm), .notNeeded)
        XCTAssertEqual(try storedUserIds(old), ["alice"])
    }

    func testPrepareCreatesDirectories() throws {
        let fresh = StorageLocation(root: tmp.appendingPathComponent("fresh"))
        AppContainer.prepare(fresh, fileManager: fm)
        XCTAssertTrue(fm.fileExists(atPath: fresh.root.path))
        XCTAssertTrue(fm.fileExists(atPath: fresh.avatarsDir.path))
    }

    /// Логаут: данные размещения стёрты, само размещение годится для новой регистрации.
    func testWipeRemovesDataAndKeepsLocationUsable() throws {
        try seed(old, userId: "alice")

        AppContainer.wipe(old, fileManager: fm)

        XCTAssertFalse(fm.fileExists(atPath: old.databaseURL.path))
        XCTAssertFalse(fm.fileExists(atPath: old.masterKeyURL.path))
        XCTAssertFalse(fm.fileExists(atPath: old.pendingMediaDir.path))
        XCTAssertTrue(fm.fileExists(atPath: old.root.path))
        XCTAssertEqual(try storedUserIds(old), [], "новая БД открывается пустой")
    }
}
