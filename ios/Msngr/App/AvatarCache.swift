import Foundation
import GRDB
import MsngrCore

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
