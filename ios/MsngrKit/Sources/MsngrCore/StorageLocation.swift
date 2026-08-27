import Foundation

/// Where persistent data lives: the database, the master key, avatars for
/// notifications, sources of offline attachments. Every path hangs off one root.
public struct StorageLocation: Sendable, Equatable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static let databaseFileName = "msngr.sqlite"
    public static let masterKeyFileName = ".masterkey"
    public static let sessionFileName = "session.json"

    public var databaseURL: URL { root.appendingPathComponent(Self.databaseFileName) }
    public var masterKeyURL: URL { root.appendingPathComponent(Self.masterKeyFileName) }
    /// Client session: userId, deviceId, token.
    public var sessionURL: URL { root.appendingPathComponent(Self.sessionFileName) }
    /// Avatars as files, so the extension reads the bytes locally without the network.
    public var avatarsDir: URL { root.appendingPathComponent("avatars") }
    /// Sources of attachments picked while offline: these survive a Caches purge.
    public var pendingMediaDir: URL { root.appendingPathComponent("media-outgoing") }
    /// Trace of the notification extension: its process shows up neither in the
    /// debugger nor in the app's console.
    public var nseJournalURL: URL { root.appendingPathComponent(NotificationJournal.fileName) }
    /// The file the crypto gate is locked on: the app and the extension step
    /// one ratchet, and the lock is what keeps them from stepping it at once.
    public var cryptoGateURL: URL { root.appendingPathComponent(CryptoGate.fileName) }

    /// What moves when the root changes. The database file goes last: its presence
    /// in the new location is what marks the move as finished.
    public static let movableItems = [
        sessionFileName,
        masterKeyFileName,
        NotificationJournal.fileName,
        "media-outgoing",
        "avatars",
        databaseFileName + "-wal",
        databaseFileName + "-shm",
        databaseFileName,
    ]
}

/// The single place storage paths are computed. Where the app group container is
/// unavailable (macOS, unit tests), Application Support stands in for it.
public enum AppContainer {
    public static let appGroupIdentifier = "group.msngr.msngr"

    /// Application Support: the location used before the group, and the fallback without it.
    public static func legacyLocation(fileManager: FileManager = .default) -> StorageLocation {
        StorageLocation(root: fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }

    /// The app group container, if the entitlement is granted and the system created it.
    public static func groupLocation(fileManager: FileManager = .default) -> StorageLocation? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
            .map(StorageLocation.init(root:))
    }

    /// The location the app works with: the group container when it is available,
    /// Application Support otherwise. Data in Application Support is moved into the
    /// group; if the move fails, work continues from the old location.
    public static func resolve(fileManager: FileManager = .default) -> StorageLocation {
        let legacy = legacyLocation(fileManager: fileManager)
        if let group = groupLocation(fileManager: fileManager) {
            do {
                try fileManager.createDirectory(at: group.root, withIntermediateDirectories: true)
                try StorageMigration.run(from: legacy, to: group, fileManager: fileManager)
                try prepare(group, fileManager: fileManager)
                return group
            } catch {
                MsngrLog.storage.error("group container unavailable, staying in Application Support: \(error)")
            }
        }
        // Application Support does not exist in a fresh container: the directory is
        // created here, otherwise writing the master key, the database and the session
        // fails on the very first access.
        do {
            try prepare(legacy, fileManager: fileManager)
        } catch {
            MsngrLog.storage.error("failed to prepare \(legacy.root.path): \(error)")
        }
        return legacy
    }

    /// Creates the directories and sets the data protection class that keeps the files
    /// readable by the extension after the device has been unlocked once.
    public static func prepare(_ location: StorageLocation, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: location.root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: location.avatarsDir, withIntermediateDirectories: true)
        applyProtection(at: location.root, fileManager: fileManager)
        applyProtection(at: location.avatarsDir, fileManager: fileManager)
        for name in StorageLocation.movableItems {
            let url = location.root.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            applyProtection(at: url, fileManager: fileManager)
        }
    }

    /// Erases the data: database, master key, avatars, attachment sources. The
    /// directories stay in place and ready, so after a logout the app can register
    /// again without a restart.
    public static func wipe(_ location: StorageLocation, fileManager: FileManager = .default) {
        for name in StorageLocation.movableItems {
            try? fileManager.removeItem(at: location.root.appendingPathComponent(name))
        }
        // the directories are recreated for the next registration; a failure here means
        // the location is unreachable, and the next session write reports that
        try? prepare(location, fileManager: fileManager)
    }

    static func applyProtection(at url: URL, fileManager: FileManager) {
        #if os(iOS)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
        #endif
    }
}

/// Moves data between locations when the storage root changes.
public enum StorageMigration {
    public enum Outcome: Sendable, Equatable {
        case notNeeded
        case migrated([String])
    }

    /// Copies the old location into a staging directory inside the new one, moves it
    /// into place, and only then removes the originals. A failure at any step leaves the
    /// old location untouched and is rethrown.
    ///
    /// Does nothing if the new location is already taken (a database is there) or if
    /// there is nothing to move, so running it again is safe. An interrupted move is
    /// finished on the next launch: the database moves last, so until it lands the new
    /// location still counts as free and whatever is left there is overwritten by the
    /// originals.
    @discardableResult
    public static func run(from old: StorageLocation,
                           to new: StorageLocation,
                           fileManager: FileManager = .default) throws -> Outcome {
        guard old.root.standardizedFileURL.path != new.root.standardizedFileURL.path else { return .notNeeded }
        guard !fileManager.fileExists(atPath: new.databaseURL.path) else { return .notNeeded }

        let present = StorageLocation.movableItems.filter {
            fileManager.fileExists(atPath: old.root.appendingPathComponent($0).path)
        }
        guard present.contains(StorageLocation.databaseFileName)
                || present.contains(StorageLocation.masterKeyFileName) else { return .notNeeded }

        let staging = new.root.appendingPathComponent(".migration-\(UUID().uuidString)")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for name in present {
                try fileManager.copyItem(at: old.root.appendingPathComponent(name),
                                         to: staging.appendingPathComponent(name))
            }
            for name in present {
                let target = new.root.appendingPathComponent(name)
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                }
                try fileManager.moveItem(at: staging.appendingPathComponent(name), to: target)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        try? fileManager.removeItem(at: staging)
        for name in present {
            try? fileManager.removeItem(at: old.root.appendingPathComponent(name))
        }
        return .migrated(present)
    }
}
