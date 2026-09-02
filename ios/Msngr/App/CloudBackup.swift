import BackgroundTasks
import CloudKit
import Foundation
import MsngrCore
import MsngrCrypto
import Security

/// The backup as iCloud keeps it: one record in the account's private CloudKit
/// database holding the sealed bytes, and the key to them in the iCloud
/// Keychain. Neither is readable by anyone but a device signed into the same
/// Apple ID, and a device that is asks the user for nothing when it restores.
/// The sealing itself is `BackupSeal`; this only moves bytes and keys.
enum CloudBackup {
    static let containerIdentifier = "iCloud.com.msngr.msngr"
    static let recordType = "Backup"

    /// Whether this device can reach the account's private database at all:
    /// false on a device with no Apple ID signed in, which is what every
    /// simulator without one reports.
    static func accountAvailable() async -> Bool {
        let status = try? await CKContainer(identifier: containerIdentifier).accountStatus()
        return status == .available
    }

    private static func record(for userId: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "account-" + userId)
    }

    /// Writes the sealed backup over whatever the account had there before.
    static func upload(_ sealed: BackupSeal.SealedBackup, userId: String) async throws -> Int {
        let data = try JSONEncoder().encode(sealed)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-backup-" + UUID().uuidString)
        try data.write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        let record = CKRecord(recordType: recordType, recordID: record(for: userId))
        record["v"] = sealed.v as CKRecordValue
        record["createdAt"] = Date() as CKRecordValue
        record["size"] = data.count as CKRecordValue
        record["blob"] = CKAsset(fileURL: file)
        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
        operation.savePolicy = .allKeys
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
        return data.count
    }

    /// The sealed backups the account holds, newest first: one per account
    /// that ever backed up from this Apple ID.
    static func fetchAll() async throws -> [(userId: String, sealed: BackupSeal.SealedBackup, createdAt: Date)] {
        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        let (matches, _) = try await database.records(matching: query, resultsLimit: 20)
        var out: [(String, BackupSeal.SealedBackup, Date)] = []
        for (id, result) in matches {
            guard case .success(let record) = result,
                  let asset = record["blob"] as? CKAsset, let url = asset.fileURL,
                  let data = try? Data(contentsOf: url),
                  let sealed = try? JSONDecoder().decode(BackupSeal.SealedBackup.self, from: data)
            else { continue }
            let userId = id.recordName.hasPrefix("account-") ? String(id.recordName.dropFirst(8)) : id.recordName
            out.append((userId, sealed, (record["createdAt"] as? Date) ?? .distantPast))
        }
        return out.sorted { $0.2 > $1.2 }.map { (userId: $0.0, sealed: $0.1, createdAt: $0.2) }
    }

    static func delete(userId: String) async throws {
        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        _ = try await database.deleteRecord(withID: record(for: userId))
    }
}

/// The key an iCloud backup is sealed under, in the iCloud Keychain: made
/// once per account, synchronised by the system to the account's devices,
/// never shown and never typed.
enum CloudBackupKey {
    private static let service = "com.msngr.msngr.backup-key"

    private static func query(userId: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: userId,
         kSecAttrSynchronizable as String: kCFBooleanTrue!]
    }

    /// The account's key, made and stored on the first ask.
    static func ensure(userId: String) throws -> Data {
        if let existing = try read(userId: userId) { return existing }
        let key = BackupSeal.generateDeviceKey()
        var attributes = query(userId: userId)
        attributes[kSecValueData as String] = key
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw Failure.keychain(status)
        }
        return try read(userId: userId) ?? key
    }

    /// The key as the keychain holds it; nil on a device that never made one
    /// and has not received one from iCloud.
    static func read(userId: String) throws -> Data? {
        var q = query(userId: userId)
        q[kSecReturnData as String] = kCFBooleanTrue
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        switch status {
        case errSecSuccess: return item as? Data
        case errSecItemNotFound: return nil
        default: throw Failure.keychain(status)
        }
    }

    static func remove(userId: String) {
        SecItemDelete(query(userId: userId) as CFDictionary)
    }

    enum Failure: Error { case keychain(OSStatus) }
}

/// When the iCloud backup runs on its own: a processing task the system
/// schedules while the device charges on a network, at most once a day.
enum BackupScheduler {
    static let taskIdentifier = "com.msngr.msngr.backup"
    /// A backup a day is plenty: the payload is the whole history, not a diff.
    static let interval: TimeInterval = 24 * 3600

    /// True when the last backup is old enough, or there was none.
    static func isDue(lastBackupAt: Date?, now: Date = Date()) -> Bool {
        guard let lastBackupAt else { return true }
        return now.timeIntervalSince(lastBackupAt) >= interval
    }

    /// Registered once at launch, before the app finishes launching.
    static func register(run: @escaping @Sendable () async -> Bool) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            let work = Task {
                let ok = await run()
                task.setTaskCompleted(success: ok)
                schedule()
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    /// Asks for the next run: on external power, with a network, no sooner
    /// than the interval after the last backup.
    static func schedule(lastBackupAt: Date? = BackupStore.lastBackupAt) {
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = lastBackupAt.map { $0.addingTimeInterval(interval) } ?? Date()
        try? BGTaskScheduler.shared.submit(request)
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    }
}
