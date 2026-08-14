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
    /// устройство отключено от аккаунта с другого устройства: поверх всего
    /// показывается экран «Сессия завершена»
    @Published var sessionRevoked = false

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

    /// Сессия лежит в подготовленном размещении рядом с БД и мастер-ключом:
    /// Application Support в контейнере приложения система не создаёт, и запись
    /// туда терялась вместе с сессией.
    private var sessionFileURL: URL { Self.storage.sessionURL }

    private func loadSession() {
        guard let data = try? Data(contentsOf: sessionFileURL),
              let s = try? JSONDecoder().decode(Session.self, from: data) else { return }
        session = s
        Task { await bootstrap(s) }
        if PinStore.hasPin() { isLocked = true }
    }

    func saveSession(_ s: Session) {
        session = s
        try? JSONEncoder().encode(s).write(to: sessionFileURL, options: .completeFileProtection)
        Task { await bootstrap(s) }
    }

    /// Общее с NSE размещение данных: контейнер app group, куда при первом запуске
    /// переезжает содержимое Application Support.
    static let storage: StorageLocation = AppContainer.resolve()

    /// Выход из аккаунта: сервер отзывает токен устройства, локально стираются
    /// сессия, БД и ключи. Ответ сервера не блокирует выход — токен всё равно
    /// остаётся только у нас, а данные уходят.
    func logout() async {
        try? await api?.logout()
        await resetToRegistration()
    }

    /// Возврат к чистому листу без перезапуска: движок остановлен, ссылки на БД
    /// отпущены, файлы хранилища и локальные настройки сессии стёрты.
    func resetToRegistration() async {
        revokedTask?.cancel()
        revokedTask = nil
        if let engine { await engine.stop() }
        NotificationCoordinator.shared.detach()
        media?.clearCache()
        engine = nil
        e2ee = nil
        store = nil
        media = nil
        api = nil
        db = nil
        ready = false
        session = nil
        OwnUser.id = ""
        UserDefaults(suiteName: AppGroup.identifier)?.removeObject(forKey: "ownUserId")
        PinStore.removePin()
        PinStore.setBiometricsEnabled(false)
        isLocked = false
        AppContainer.wipe(Self.storage)
    }


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
            observeSessionRevoked(engine)
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

    private var revokedTask: Task<Void, Never>?

    /// Сервер отключил устройство от аккаунта: переподключаться некуда,
    /// показываем экран завершённой сессии.
    private func observeSessionRevoked(_ engine: SyncEngine) {
        revokedTask?.cancel()
        revokedTask = Task { [weak self] in
            for await _ in engine.sessionRevokedStream.subscribe() {
                guard let self else { return }
                self.sessionRevoked = true
            }
        }
    }

    /// Уход с экрана «Сессия завершена»: локальные данные отозванного
    /// устройства стираются, пользователь возвращается к регистрации.
    func finishRevokedSession() async {
        await resetToRegistration()
        sessionRevoked = false
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
