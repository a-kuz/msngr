import Foundation
import GRDB
import MsngrCore
import UIKit

/// Avatars as files in the container shared with the NSE: `avatars/<avatarId>.jpg`.
/// A notification needs the image bytes locally (INImage is built from data),
/// and the extension has no network to reach for them at that moment.
actor AvatarCache {
    static let shared = AvatarCache()

    private let dir: URL
    private var inFlight: [String: Task<URL?, Never>] = [:]

    init(directory: URL = AppContainer.resolve().avatarsDir) {
        dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// A file that is already downloaded; nil means it still has to be fetched.
    nonisolated func cachedFile(_ avatarId: String?) -> URL? {
        guard let avatarId, !avatarId.isEmpty else { return nil }
        let url = dir.appendingPathComponent(avatarId + ".jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Cached file, downloading it when missing. On nil there is no image and
    /// the notification is shown without one.
    func ensure(_ avatarId: String?, api: APIClient?) async -> URL? {
        guard let avatarId, !avatarId.isEmpty else { return nil }
        if let cached = cachedFile(avatarId) { return cached }
        guard let api else { return nil }
        if let running = inFlight[avatarId] { return await running.value }
        let task = Task<URL?, Never> { [dir] in
            guard let data = try? await api.avatarData(avatarId), !data.isEmpty else { return nil }
            let url = dir.appendingPathComponent(avatarId + ".jpg")
            try? data.write(to: url, options: .atomic)
            return url
        }
        inFlight[avatarId] = task
        let url = await task.value
        inFlight[avatarId] = nil
        return url
    }

    /// Drops the file of an id whose bytes turned out to be unusable, so the
    /// next ask downloads it again instead of decoding the same bad file.
    func discard(_ avatarId: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(avatarId + ".jpg"))
    }

    /// Pulls in avatars of every known contact and group: by the time a
    /// notification arrives the image has to be on disk already.
    func prefetchAll(db: DatabaseQueue, api: APIClient) async {
        let ids = (try? await db.read { dbc in
            try String.fetchAll(dbc, sql: "SELECT avatarId FROM user WHERE avatarId IS NOT NULL")
                + String.fetchAll(dbc, sql: "SELECT avatarId FROM chat WHERE avatarId IS NOT NULL")
        }) ?? []
        for id in Set(ids) where cachedFile(id) == nil {
            _ = await ensure(id, api: api)
        }
    }
}

/// What an avatar blob turned out to be: a picture, or a shader document the
/// owner put up in its place.
enum AvatarPicture {
    case image(UIImage)
    case shader(ShaderDocument)

    var image: UIImage? {
        if case .image(let i) = self { return i }
        return nil
    }

    var shader: ShaderDocument? {
        if case .shader(let d) = self { return d }
        return nil
    }
}

/// Decoded avatars for the screen. A chat list scrolls the same faces past the
/// eye over and over, and reading plus decoding a JPEG per row per appearance
/// is work with one answer; an id changes only when its owner puts up a new
/// picture, so the entry never goes stale.
actor AvatarImageLoader {
    static let shared = AvatarImageLoader()

    private final class Box {
        let picture: AvatarPicture
        init(_ p: AvatarPicture) { picture = p }
    }

    private let cache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.countLimit = 200
        return c
    }()
    private var inFlight: [String: Task<AvatarPicture?, Never>] = [:]

    func image(_ avatarId: String) async -> UIImage? {
        await picture(avatarId)?.image
    }

    /// The avatar as a picture or as a shader: a blob that starts with `{`
    /// and parses as a document is a shader avatar.
    func picture(_ avatarId: String) async -> AvatarPicture? {
        if let hit = cache.object(forKey: avatarId as NSString) { return hit.picture }
        if let running = inFlight[avatarId] { return await running.value }
        let task = Task<AvatarPicture?, Never> {
            let api = await AppState.shared.api
            guard let url = await AvatarCache.shared.ensure(avatarId, api: api) else { return nil }
            guard let data = try? Data(contentsOf: url) else { return nil }
            if data.first == UInt8(ascii: "{"),
               let doc = try? JSONDecoder().decode(ShaderDocument.self, from: data), doc.image != nil {
                return .shader(doc)
            }
            guard let image = UIImage(data: data) else {
                // half a file, or bytes that are not an image: keeping it would
                // answer every later ask with the same nothing
                await AvatarCache.shared.discard(avatarId)
                return nil
            }
            return .image(image)
        }
        inFlight[avatarId] = task
        let picture = await task.value
        inFlight[avatarId] = nil
        if let picture { cache.setObject(Box(picture), forKey: avatarId as NSString) }
        return picture
    }
}
