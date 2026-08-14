import SwiftUI
import GRDB
import MsngrCore
import LocalAuthentication

struct Session: Codable {
    var userId: String
    var deviceId: String
    var token: String
    var username: String
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // Конфиг сервера: для локальной разработки — wrangler dev.
    static let httpBase = URL(string: ProcessInfo.processInfo.environment["MSNGR_SERVER"] ?? "http://localhost:8787")!

    @Published var session: Session?
    @Published var isLocked = false
    @Published var obscured = false
    /// true, когда db/engine инициализированы (bootstrap завершён)
    @Published var ready = false

    private(set) var db: DatabaseQueue!
    private(set) var api: APIClient!
    private(set) var engine: SyncEngine!
    private(set) var e2ee: E2EEManager!
    private(set) var media: MediaManager!
    private(set) var store: IdentityStore!

    private init() {
        loadSession()
    }

    // MARK: - Session

    private var sessionFileURL: URL { Self.storage.sessionURL }

    private func loadSession() {
        let url = sessionFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let s: Session
        do {
            s = try JSONDecoder().decode(Session.self, from: Data(contentsOf: url))
        } catch {
            MsngrLog.session.error("не удалось прочитать \(url.path): \(error)")
            return
        }
        session = s
        Task { await bootstrap(s) }
        if PinStore.hasPin() { isLocked = true }
    }

    /// Сохраняет сессию на диск и поднимает ядро. Ошибка записи означает, что
    /// после перезапуска пользователь окажется на экране регистрации, поэтому
    /// она пробрасывается вызывающему, а не глотается.
    func saveSession(_ s: Session) throws {
        // размещение готовится при первом обращении к storage, но каталог могли
        // удалить снаружи, а запись в несуществующий каталог падает
        try AppContainer.prepare(Self.storage)
        // защита как у мастер-ключа: файл доступен после первой разблокировки,
        // иначе запуск в фоне на заблокированном устройстве не увидит сессию
        try JSONEncoder().encode(s).write(
            to: sessionFileURL, options: [.completeFileProtectionUntilFirstUserAuthentication, .atomic])
        session = s
        Task { await bootstrap(s) }
    }

    /// Общее с NSE размещение данных: контейнер app group, куда при первом запуске
    /// переезжает содержимое Application Support.
    static let storage: StorageLocation = AppContainer.resolve()


    private func bootstrap(_ s: Session) async {
        OwnUser.id = s.userId
        // NSE читает эти значения из shared defaults
        UserDefaults(suiteName: AppGroup.identifier)?.set(s.userId, forKey: "ownUserId")
        do {
            let storage = Self.storage
            db = try AppDatabase.open(at: storage.databaseURL)
            api = APIClient(baseURL: Self.httpBase, token: s.token)
            store = try IdentityStore(db: db, masterKeyProvider: SharedFileMasterKey(location: storage))
            e2ee = E2EEManager(store: store, api: api, ownUserId: s.userId, ownDeviceId: s.deviceId)
            // pendingDir — в постоянном контейнере: исходники офлайн-вложений
            // должны пережить чистку Caches до выгрузки
            media = MediaManager(api: api,
                                 cacheDir: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                                     .appendingPathComponent("media"),
                                 pendingDir: storage.pendingMediaDir)
            var comps = URLComponents(url: Self.httpBase.appendingPathComponent("ws"), resolvingAgainstBaseURL: false)!
            comps.scheme = Self.httpBase.scheme == "https" ? "wss" : "ws"
            comps.queryItems = [URLQueryItem(name: "token", value: s.token)]
            engine = SyncEngine(db: db, api: api, e2ee: e2ee, media: media, wsURL: comps.url!,
                                ownUserId: s.userId, ownDeviceId: s.deviceId)
            await engine.start()
            ready = true
            objectWillChange.send()
            NotificationCoordinator.shared.attach(db: db, engine: engine, ownUserId: s.userId)
            #if targetEnvironment(simulator)
            // симулятору APNs недоступен: дев-стенд шлёт пуши через `simctl push`
            // по UDID, он же регистрируется на сервере вместо APNs-токена
            let udid = ProcessInfo.processInfo.environment["SIMULATOR_UDID"] ?? "unknown-simulator"
            try? await api.registerPushToken(udid, env: "dev-sim")
            // APNs симулятору недоступен: баннер в фоне постит приложение
            NotificationCoordinator.shared.apnsAvailable = false
            #else
            UIApplication.shared.registerForRemoteNotifications()
            #endif
        } catch {
            assertionFailure("bootstrap failed: \(error)")
        }
    }

    func registerPushToken(_ token: String) async {
        #if DEBUG
        let env = "sandbox"
        #else
        let env = "production"
        #endif
        try? await api?.registerPushToken(token, env: env)
    }

    // MARK: - Lifecycle / lock

    private var backgroundedAt: Date?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            obscured = true
            backgroundedAt = Date()
            beginBackgroundWork()
            if let engine { Task { await engine.appEnteredBackground() } }
        case .inactive:
            obscured = true
        case .active:
            obscured = false
            endBackgroundWork()
            if let engine { Task { await engine.appBecameActive() } }
            // авто-лок: пин есть и в фоне были дольше грейс-периода
            if PinStore.hasPin(), let t = backgroundedAt,
               Date().timeIntervalSince(t) > PinStore.autolockInterval {
                isLocked = true
            }
            backgroundedAt = nil
        @unknown default:
            break
        }
    }

    /// Без этого процесс усыпляют сразу после сворачивания, и сообщение,
    /// пришедшее по живому WS, остаётся без уведомления. Система даёт около
    /// 30 секунд — этого хватает дочитать входящие и поднять баннер.
    private func beginBackgroundWork() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ws-incoming") { [weak self] in
            Task { @MainActor in self?.endBackgroundWork() }
        }
    }

    private func endBackgroundWork() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    func unlock() {
        isLocked = false
    }

    func tryBiometrics() {
        guard PinStore.biometricsEnabled() else { return }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else { return }
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                           localizedReason: "Разблокировать Msngr") { [weak self] ok, _ in
            if ok { Task { @MainActor in self?.unlock() } }
        }
    }
}
