import Foundation
import CryptoKit
import MsngrCrypto

/// Шифрованные медиа: upload (encrypt → R2), download (R2 → verify → decrypt → кэш).
/// Кэш плоский на диске: ключ = mediaId, значение = plaintext.
/// pendingDir — постоянная (не Caches) папка исходников медиа, приложенных офлайн:
/// файл живёт там до успешной выгрузки outbox-воркером.
public final class MediaManager: @unchecked Sendable {
    public enum MediaError: Error { case pendingFileMissing }

    private let api: APIClient
    private let cacheDir: URL
    private let pendingDir: URL
    private var inflight: [String: Task<URL, Error>] = [:]
    private let lock = NSLock()

    public init(api: APIClient, cacheDir: URL, pendingDir: URL? = nil) {
        self.api = api
        self.cacheDir = cacheDir
        self.pendingDir = pendingDir
            ?? cacheDir.deletingLastPathComponent().appendingPathComponent("media-outgoing")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: self.pendingDir, withIntermediateDirectories: true)
    }

    public func cachedURL(for mediaId: String) -> URL? {
        let url = cacheDir.appendingPathComponent(mediaId)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Локальные исходники (ещё не выгруженные медиа)

    /// Кладёт plaintext в pendingDir; возвращает имя файла для MediaInfo.localPath.
    public func stash(_ plaintext: Data) throws -> String {
        let name = UUID().uuidString
        try plaintext.write(to: pendingDir.appendingPathComponent(name), options: .atomic)
        return name
    }

    public func pendingURL(for localName: String) -> URL? {
        let url = pendingDir.appendingPathComponent(localName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Выгружает локальный исходник; вызывается outbox-воркером перед шифрованием конверта.
    public func uploadPending(localName: String) async throws -> (mediaId: String, key: String, hash: String, size: Int) {
        guard let url = pendingURL(for: localName) else { throw MediaError.pendingFileMissing }
        return try await upload(try Data(contentsOf: url))
    }

    public func removePending(localName: String) {
        try? FileManager.default.removeItem(at: pendingDir.appendingPathComponent(localName))
    }

    /// Шифрует и выгружает; возвращает поля для MediaInfo. Plaintext кладётся в кэш сразу
    /// (отправитель видит своё медиа мгновенно).
    public func upload(_ plaintext: Data) async throws -> (mediaId: String, key: String, hash: String, size: Int) {
        let enc = try MediaCrypto.encrypt(plaintext)
        let res = try await api.uploadMedia(enc.ciphertext)
        let local = cacheDir.appendingPathComponent(res.mediaId)
        try? plaintext.write(to: local, options: .atomic)
        return (res.mediaId, enc.key.base64EncodedString(), enc.sha256.base64EncodedString(), plaintext.count)
    }

    /// Скачивает, проверяет хэш, расшифровывает, кэширует. Дедуп одновременных запросов.
    /// Ещё не выгруженное своё медиа (mediaId пустой) отдаётся из pendingDir.
    public func fetch(_ media: MediaInfo) async throws -> URL {
        if media.mediaId.isEmpty {
            guard let name = media.localPath, let url = pendingURL(for: name) else {
                throw MediaError.pendingFileMissing
            }
            return url
        }
        if let cached = cachedURL(for: media.mediaId) { return cached }
        lock.lock()
        if let existing = inflight[media.mediaId] {
            lock.unlock()
            return try await existing.value
        }
        let task = Task<URL, Error> {
            defer {
                self.lock.lock()
                self.inflight[media.mediaId] = nil
                self.lock.unlock()
            }
            guard let key = Data(base64Encoded: media.key),
                  let hash = Data(base64Encoded: media.hash) else {
                throw CryptoError.invalidKey
            }
            let ciphertext = try await self.api.downloadMedia(media.mediaId)
            let plaintext = try MediaCrypto.decrypt(ciphertext, key: key, expectedSHA256: hash)
            let url = self.cacheDir.appendingPathComponent(media.mediaId)
            try plaintext.write(to: url, options: .atomic)
            return url
        }
        inflight[media.mediaId] = task
        lock.unlock()
        return try await task.value
    }

    /// Превью-блоб (thumb видео) по отдельным полям MediaInfo.
    public func fetchThumb(_ media: MediaInfo) async throws -> URL? {
        guard let id = media.thumbMediaId, let keyB64 = media.thumbKey, let hashB64 = media.thumbHash else { return nil }
        var t = MediaInfo(type: "photo", mediaId: id, key: keyB64, hash: hashB64, size: 0, mime: "image/jpeg")
        return try await fetch(t)
    }

    public func totalCacheSize() -> Int64 {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(0) { acc, url in
            acc + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    public func clearCache() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else { return }
        for url in items { try? fm.removeItem(at: url) }
    }
}
