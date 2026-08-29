import Foundation
import CryptoKit
import MsngrCrypto

/// Encrypted media: upload (encrypt → R2), download (R2 → verify → decrypt → cache).
/// The disk cache is flat: mediaId is the key, plaintext is the value.
/// pendingDir is a permanent directory (not Caches) holding originals attached while offline;
/// a file stays there until the outbox worker has uploaded it.
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

    /// AVPlayer picks the container from the file extension, so video and audio will not
    /// open without one. Images are decoded by content and do not care.
    public static func fileExtension(forMime mime: String?) -> String {
        switch mime?.lowercased() {
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "audio/m4a", "audio/mp4", "audio/aac", "audio/x-m4a": return "m4a"
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/heic": return "heic"
        case "image/gif": return "gif"
        default: return "bin"
        }
    }

    private func cacheFileName(_ mediaId: String, mime: String?) -> String {
        mediaId + "." + Self.fileExtension(forMime: mime)
    }

    public func cachedURL(for mediaId: String, mime: String? = nil) -> URL? {
        let url = cacheDir.appendingPathComponent(cacheFileName(mediaId, mime: mime))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Local originals (media not uploaded yet)

    /// Writes the plaintext into pendingDir and returns the file name for MediaInfo.localPath.
    public func stash(_ plaintext: Data, mime: String? = nil) throws -> String {
        let name = UUID().uuidString + "." + Self.fileExtension(forMime: mime)
        try plaintext.write(to: pendingDir.appendingPathComponent(name), options: .atomic)
        return name
    }

    public func pendingURL(for localName: String) -> URL? {
        let url = pendingDir.appendingPathComponent(localName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Uploads a local original; called by the outbox worker before it encrypts the envelope.
    public func uploadPending(localName: String, mime: String? = nil,
                              progress: (@Sendable (Double) -> Void)? = nil) async throws -> (mediaId: String, key: String, hash: String, size: Int) {
        guard let url = pendingURL(for: localName) else { throw MediaError.pendingFileMissing }
        return try await upload(try Data(contentsOf: url), mime: mime, progress: progress)
    }

    public func removePending(localName: String) {
        try? FileManager.default.removeItem(at: pendingDir.appendingPathComponent(localName))
    }

    /// Encrypts and uploads, returning the fields for MediaInfo. The plaintext goes into the
    /// cache right away so the sender sees their own media without a round trip.
    public func upload(_ plaintext: Data, mime: String? = nil,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws -> (mediaId: String, key: String, hash: String, size: Int) {
        let enc = try MediaCrypto.encrypt(plaintext)
        let res = try await api.uploadMedia(enc.ciphertext, progress: progress)
        let local = cacheDir.appendingPathComponent(cacheFileName(res.mediaId, mime: mime))
        try? plaintext.write(to: local, options: .atomic)
        return (res.mediaId, enc.key.base64EncodedString(), enc.sha256.base64EncodedString(), plaintext.count)
    }

    /// Downloads, verifies the hash, decrypts and caches; concurrent requests are deduplicated.
    /// Our own media that has not been uploaded yet (empty mediaId) is served from pendingDir.
    public func fetch(_ media: MediaInfo) async throws -> URL {
        if media.mediaId.isEmpty {
            guard let name = media.localPath, let url = pendingURL(for: name) else {
                throw MediaError.pendingFileMissing
            }
            return url
        }
        if let cached = cachedURL(for: media.mediaId, mime: media.mime) { return cached }
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
            let url = self.cacheDir.appendingPathComponent(self.cacheFileName(media.mediaId, mime: media.mime))
            try plaintext.write(to: url, options: .atomic)
            return url
        }
        inflight[media.mediaId] = task
        lock.unlock()
        return try await task.value
    }

    /// The preview blob (a video's thumbnail), addressed by its own fields in MediaInfo.
    public func fetchThumb(_ media: MediaInfo) async throws -> URL? {
        guard let id = media.thumbMediaId, let keyB64 = media.thumbKey, let hashB64 = media.thumbHash else { return nil }
        var t = MediaInfo(type: "photo", mediaId: id, key: keyB64, hash: hashB64, size: 0, mime: "image/jpeg")
        return try await fetch(t)
    }

    /// Places plaintext directly into the cache under its mediaId, as a restore
    /// does with the bytes a backup carried: the file behaves exactly like one
    /// `fetch` downloaded, with no round trip to the server.
    public func seedCache(mediaId: String, mime: String?, data: Data) throws {
        let url = cacheDir.appendingPathComponent(cacheFileName(mediaId, mime: mime))
        try data.write(to: url, options: .atomic)
    }

    public func totalCacheSize() -> Int64 {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(0) { acc, url in
            acc + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Drops the local files of one attachment: the blob, its preview frame and
    /// any source still waiting to be uploaded. A copy forwarded into another
    /// chat carries the same mediaId and is downloaded again when it is opened.
    public func remove(_ info: MediaInfo) {
        let fm = FileManager.default
        if !info.mediaId.isEmpty {
            try? fm.removeItem(at: cacheDir.appendingPathComponent(cacheFileName(info.mediaId, mime: info.mime)))
        }
        if let thumb = info.thumbMediaId {
            try? fm.removeItem(at: cacheDir.appendingPathComponent(cacheFileName(thumb, mime: "image/jpeg")))
        }
        if let name = info.localPath { removePending(localName: name) }
        if let name = info.thumbLocalPath { removePending(localName: name) }
    }

    public func clearCache() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else { return }
        for url in items { try? fm.removeItem(at: url) }
    }
}
