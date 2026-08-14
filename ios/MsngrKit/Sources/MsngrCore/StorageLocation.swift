import Foundation

/// Размещение постоянных данных: БД, мастер-ключ, аватары для уведомлений,
/// исходники офлайн-вложений. Все пути считаются от одного корня.
public struct StorageLocation: Sendable, Equatable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static let databaseFileName = "msngr.sqlite"
    public static let masterKeyFileName = ".masterkey"
    public static let sessionFileName = "session.json"

    public var databaseURL: URL { root.appendingPathComponent(Self.databaseFileName) }
    public var masterKeyURL: URL { root.appendingPathComponent(Self.masterKeyFileName) }
    /// Сессия клиента: userId, deviceId, токен.
    public var sessionURL: URL { root.appendingPathComponent(Self.sessionFileName) }
    /// Аватары файлами: NSE читает байты локально, без сети.
    public var avatarsDir: URL { root.appendingPathComponent("avatars") }
    /// Исходники вложений, приложенных офлайн: переживают чистку Caches.
    public var pendingMediaDir: URL { root.appendingPathComponent("media-outgoing") }

    /// Содержимое размещения, которое переносится при смене корня. Файл БД —
    /// последний: его наличие в новом размещении означает, что перенос завершён.
    public static let movableItems = [
        masterKeyFileName,
        sessionFileName,
        "media-outgoing",
        "avatars",
        databaseFileName + "-wal",
        databaseFileName + "-shm",
        databaseFileName,
    ]
}

/// Единая точка вычисления путей хранилища.
///
/// Приложение и Notification Service Extension работают с одними и теми же
/// файлами через контейнер app group. Там, где группа недоступна (macOS,
/// юнит-тесты), используется Application Support.
public enum AppContainer {
    public static let appGroupIdentifier = "group.ai.enface.msngr"

    /// Application Support: размещение до перехода в группу и фолбэк без группы.
    public static func legacyLocation(fileManager: FileManager = .default) -> StorageLocation {
        StorageLocation(root: fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }

    /// Контейнер app group, если entitlement выдан и контейнер создан системой.
    public static func groupLocation(fileManager: FileManager = .default) -> StorageLocation? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
            .map(StorageLocation.init(root:))
    }

    /// Возвращает размещение, с которым работает приложение: контейнер группы,
    /// если он доступен, иначе Application Support. Данные из Application Support
    /// переносятся в группу; если перенос не удался, работа продолжается со
    /// старого размещения.
    public static func resolve(fileManager: FileManager = .default) -> StorageLocation {
        let legacy = legacyLocation(fileManager: fileManager)
        if let group = groupLocation(fileManager: fileManager) {
            do {
                try fileManager.createDirectory(at: group.root, withIntermediateDirectories: true)
                try StorageMigration.run(from: legacy, to: group, fileManager: fileManager)
                try prepare(group, fileManager: fileManager)
                return group
            } catch {
                MsngrLog.storage.error("контейнер группы недоступен, работаем в Application Support: \(error)")
            }
        }
        // Application Support в свежем контейнере не существует: каталог создаётся здесь,
        // иначе запись мастер-ключа, БД и сессии упадёт на первом же обращении.
        do {
            try prepare(legacy, fileManager: fileManager)
        } catch {
            MsngrLog.storage.error("не удалось подготовить \(legacy.root.path): \(error)")
        }
        return legacy
    }

    /// Создаёт каталоги размещения и выставляет защиту данных, при которой файлы
    /// доступны расширению после первой разблокировки устройства.
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

    static func applyProtection(at url: URL, fileManager: FileManager) {
        #if os(iOS)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
        #endif
    }
}

/// Перенос данных между размещениями при смене корня хранилища.
public enum StorageMigration {
    public enum Outcome: Sendable, Equatable {
        case notNeeded
        case migrated([String])
    }

    /// Копирует содержимое старого размещения во временный каталог внутри нового,
    /// перемещает на место и только после этого удаляет оригиналы. Ошибка на любом
    /// шаге оставляет старое размещение нетронутым и пробрасывается наверх.
    ///
    /// Ничего не делает, если новое размещение уже занято (там есть БД) или если
    /// переносить нечего — повторный запуск безопасен. Прерванный перенос
    /// доводится до конца на следующем запуске: БД перемещается последней, так
    /// что до неё новое размещение считается незанятым, а остатки в нём
    /// заменяются оригиналами.
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
