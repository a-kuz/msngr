import Foundation
import GRDB
import MsngrCore

/// Аватары файлами в общем с NSE контейнере: `avatars/<avatarId>.jpg`.
/// Уведомлению нужны байты картинки локально (INImage строится из данных),
/// сеть в этот момент недоступна расширению.
actor AvatarCache {
    static let shared = AvatarCache()

    private let dir: URL
    private var inFlight: [String: Task<URL?, Never>] = [:]

    init(directory: URL = AppState.sharedContainer.appendingPathComponent("avatars")) {
        dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Уже скачанный файл; nil — качать надо отдельно.
    nonisolated func cachedFile(_ avatarId: String?) -> URL? {
        guard let avatarId, !avatarId.isEmpty else { return nil }
        let url = dir.appendingPathComponent(avatarId + ".jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Файл из кэша, при отсутствии — скачивает. nil — картинки не будет,
    /// уведомление показывается без неё.
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

    /// Догружает аватары всех известных собеседников и групп: к моменту
    /// уведомления картинка уже должна лежать на диске.
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
