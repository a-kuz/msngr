import SwiftUI
import GRDB
import MsngrCore
import MsngrCalls
import LocalAuthentication

/// What this build has run into that a newer one handles. Both endings look the
/// same to the user — the app is behind — but only one of them has an action
/// that changes anything.
enum OutdatedBuild {
    /// The server no longer serves this build's protocol version, and the
    /// reconnect loop has stopped.
    case protocolRefused
    /// The database on the device was written by a newer build, so this one
    /// leaves it closed rather than migrating on top of it.
    case storageAhead
}

struct Session: Codable {
    var userId: String
    var deviceId: String
    var token: String
    var username: String
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // Server config: wrangler dev for local development. The build scheme puts
    // an empty string into MSNGR_SERVER when no stand is set, so the variable is
    // used only when it parses into a URL
    static let httpBase: URL = {
        if let raw = ProcessInfo.processInfo.environment["MSNGR_SERVER"],
           let url = URL(string: raw), url.scheme != nil { return url }
        // a physical device gets no environment: `make device` bakes the stand
        // it was told to use into the Info instead (empty when not a device build)
        if let raw = Bundle.main.object(forInfoDictionaryKey: "MSNGRServer") as? String,
           let url = URL(string: raw), url.scheme != nil { return url }
        // the tunnel is the one address that holds everywhere the app runs: on a
        // device loopback is the phone itself. A build that wants the stand
        // directly says so through MSNGR_SERVER
        return URL(string: "https://msngr.a-kuz.online")!
    }()

    @Published var session: Session?
    @Published var isLocked = false
    @Published var obscured = false
    /// true once db/engine are initialised (bootstrap finished)
    @Published var ready = false
    /// the device was cut off from the account from another device; the
    /// session-ended screen covers everything else
    @Published var sessionRevoked = false
    /// this build is behind what it has to work with; the screen states it
    @Published var outdated: OutdatedBuild?

    /// the one call this device can be in, mirrored for the overlay
    @Published var callState = CallState()
    /// the call folded into the floating tile so the app is usable underneath
    @Published var callMinimized = false

    private(set) var db: DatabaseQueue!
    private(set) var api: APIClient!
    private(set) var engine: SyncEngine!
    private(set) var callManager: CallManager!
    private var callStateTask: Task<Void, Never>?
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
            MsngrLog.session.error("failed to read \(url.path): \(error)")
            return
        }
        session = s
        Task { await bootstrap(s) }
        if PinStore.hasPin() { isLocked = true }
    }

    /// Writes the session to disk and brings the core up. A failed write leaves
    /// the user on the registration screen after a restart, so the error goes to
    /// the caller instead of being swallowed.
    func saveSession(_ s: Session) throws {
        try writeSession(s)
        Task { await bootstrap(s) }
    }

    /// The account's handle changed. The core is already up and the account is
    /// the same one, so only the copy on disk and the one the screens read are
    /// rewritten; a bootstrap here would drop the socket over a name.
    func updateSessionUsername(_ username: String) throws {
        guard var s = session else { return }
        s.username = username
        try writeSession(s)
    }

    private func writeSession(_ s: Session) throws {
        // the location is prepared on the first use of storage, but the
        // directory can be removed from outside, and writing into a directory
        // that is not there fails
        try AppContainer.prepare(Self.storage)
        // same protection as the master key: the file is readable after the
        // first unlock, otherwise a background launch on a locked device sees
        // no session
        try JSONEncoder().encode(s).write(
            to: sessionFileURL, options: [.completeFileProtectionUntilFirstUserAuthentication, .atomic])
        session = s
    }

    /// Data location shared with the NSE: the app group container, into which
    /// the contents of Application Support move on first launch.
    static let storage: StorageLocation = AppContainer.resolve()

    /// Signing out: the server revokes the device token, and the session, the
    /// database and the keys are erased locally. The server's answer does not
    /// hold the logout back, since the token is ours alone and the data goes
    /// either way.
    func logout() async {
        try? await api?.logout()
        await resetToRegistration()
    }

    /// Back to a clean slate without a restart: the engine is stopped, database
    /// references are released, storage files and local session settings erased.
    func resetToRegistration() async {
        revokedTask?.cancel()
        revokedTask = nil
        outdatedTask?.cancel()
        outdatedTask = nil
        if let callManager { await callManager.hangUp() }
        callStateTask?.cancel()
        callStateTask = nil
        callManager = nil
        callState = CallState()
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
        isLocked = false
        Self.wipeLocalData()
    }

    /// Everything an account leaves on the device: storage files, passcode,
    /// shared defaults. A new account must inherit none of it.
    static func wipeLocalData() {
        AppContainer.wipe(storage)
        PinStore.removePin()
        PinStore.setBiometricsEnabled(false)
        UserDefaults(suiteName: AppGroup.identifier)?.removeObject(forKey: "ownUserId")
    }

    private func bootstrap(_ s: Session) async {
        let storage = Self.storage
        // the container survives the account: a database owned by somebody else
        // means the device identity of this session is gone with it, so there is
        // nothing to resume — back to registration on clean storage
        // storage without a marker predates it: the session names the owner, so
        // it is stamped below rather than thrown away
        if StorageOwnership.decision(owner: StorageOwnership.owner(at: storage.databaseURL),
                                     expectedUserId: s.userId) == .wipe {
            MsngrLog.session.error("local storage belongs to another account, resetting to registration")
            await resetToRegistration()
            return
        }
        OwnUser.id = s.userId
        // the NSE reads these values from the shared defaults
        UserDefaults(suiteName: AppGroup.identifier)?.set(s.userId, forKey: "ownUserId")
        // the extension answers the delivery receipt over HTTP and is launched
        // by the system, so the address of the stand has to reach it from here
        ServerEndpoint.setBase(Self.httpBase, in: AppGroup.defaults)
        do {
            db = try AppDatabase.open(at: storage.databaseURL)
            try StorageOwnership.stamp(db, userId: s.userId)
            api = AppNet.client(token: s.token)
            store = try IdentityStore(db: db, masterKeyProvider: SharedFileMasterKey(location: storage))
            // the extension steps the same ratchet from its own process; the
            // gate is what keeps the two of them out of one step
            e2ee = E2EEManager(store: store, api: api, ownUserId: s.userId, ownDeviceId: s.deviceId,
                               gate: CryptoGate.shared(location: storage))
            // pendingDir sits in the permanent container: originals of offline
            // attachments have to survive a Caches purge until they are uploaded
            media = MediaManager(api: api,
                                 cacheDir: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                                     .appendingPathComponent("media"),
                                 pendingDir: storage.pendingMediaDir)
            media?.cacheCeilingBytes = MediaCacheCeiling.current.bytes
            media?.enforceCacheCeiling()
            var comps = URLComponents(url: Self.httpBase.appendingPathComponent("ws"), resolvingAgainstBaseURL: false)!
            comps.scheme = Self.httpBase.scheme == "https" ? "wss" : "ws"
            comps.queryItems = [URLQueryItem(name: "token", value: s.token)]
            engine = SyncEngine(db: db, api: api, e2ee: e2ee, media: media, wsURL: comps.url!,
                                ownUserId: s.userId, ownDeviceId: s.deviceId)
            await engine.start()
            // the call gate fails closed: an offer whose permission cannot be
            // judged is answered busy rather than rung through the setting
            callManager = CallManager(
                engine: engine,
                mayCall: { [api] caller in
                    (try? await api?.mayCall(peerId: caller)) ?? false
                },
                makeTransport: { try WebRTCTransport() },
                openChat: { userId in await DirectChat.open(userId: userId) })
            observeCallState(callManager)
            observeSessionRevoked(engine)
            observeProtocolOutdated(engine)
            ready = true
            objectWillChange.send()
            NotificationCoordinator.shared.attach(db: db, engine: engine, ownUserId: s.userId)
            #if targetEnvironment(simulator)
            // no APNs on the simulator: the dev stand delivers pushes with
            // `simctl push` by UDID, and that UDID is registered on the server
            // in place of an APNs token
            let udid = ProcessInfo.processInfo.environment["SIMULATOR_UDID"] ?? "unknown-simulator"
            try? await api.registerPushToken(udid, env: "dev-sim")
            // with no push arriving, the app posts the background banner itself
            NotificationCoordinator.shared.apnsAvailable = false
            #else
            UIApplication.shared.registerForRemoteNotifications()
            #endif
        } catch AppDatabaseError.schemaFromNewerVersion(let applied) {
            // storage written by a newer build: it is left as it is, and the
            // screen offers the only thing this build can do about it
            MsngrLog.session.error(
                "storage is ahead of this build: \(applied.joined(separator: ","), privacy: .public)")
            db = nil
            outdated = .storageAhead
        } catch {
            assertionFailure("bootstrap failed: \(error)")
        }
    }

    private var outdatedTask: Task<Void, Never>?

    /// The server no longer serves this build's protocol version: there will be
    /// no reconnect, so the outdated-build screen takes over.
    private func observeProtocolOutdated(_ engine: SyncEngine) {
        outdatedTask?.cancel()
        outdatedTask = Task { [weak self] in
            for await _ in engine.protocolOutdatedStream.subscribe() {
                guard let self else { return }
                self.outdated = .protocolRefused
            }
        }
    }

    /// The one thing this build can do about storage newer than itself: start
    /// over on clean storage. The user decides, because the data goes.
    func startOverOnCleanStorage() async {
        await resetToRegistration()
        outdated = nil
    }

    private var revokedTask: Task<Void, Never>?

    /// The server has cut this device off the account: there is nothing left to
    /// reconnect to, so the session-ended screen goes up.
    private func observeCallState(_ manager: CallManager) {
        callStateTask?.cancel()
        let states = manager.stateStream.subscribe()
        callStateTask = Task { [weak self] in
            for await state in states {
                self?.callState = state
                CallSounds.shared.apply(state.phase)
                switch state.phase {
                case .idle:
                    self?.callMinimized = false
                case .ended:
                    // unfold so the outcome is seen, then dismiss: the screen
                    // may be re-created by the unfold itself, so the timer
                    // lives here rather than in a view callback
                    self?.callMinimized = false
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        await self?.callManager?.reset()
                    }
                default:
                    break
                }
            }
        }
    }

    private func observeSessionRevoked(_ engine: SyncEngine) {
        revokedTask?.cancel()
        revokedTask = Task { [weak self] in
            for await _ in engine.sessionRevokedStream.subscribe() {
                guard let self else { return }
                self.sessionRevoked = true
            }
        }
    }

    /// Leaving the session-ended screen: the revoked device's local data is
    /// wiped and the user is taken back to registration.
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
            // auto-lock: there is a PIN and the app sat in the background longer
            // than the grace period
            if PinStore.hasPin(), let t = backgroundedAt,
               Date().timeIntervalSince(t) > PinStore.autolockInterval {
                isLocked = true
            }
            backgroundedAt = nil
        @unknown default:
            break
        }
    }

    /// Without this the process is suspended as soon as the app is backgrounded,
    /// and a message arriving over the live WS never raises a notification. The
    /// system grants around 30 seconds, enough to finish reading the incoming
    /// messages and put up the banner.
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
                           localizedReason: String(localized: "Unlock Msngr")) { [weak self] ok, _ in
            if ok { Task { @MainActor in self?.unlock() } }
        }
    }
}
