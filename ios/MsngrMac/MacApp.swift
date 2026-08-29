import SwiftUI
import GRDB
import MsngrCore
import MsngrCrypto

@main
struct MsngrMacApp: App {
    @StateObject private var app = MacAppState()

    var body: some Scene {
        WindowGroup {
            Group {
                if app.session != nil {
                    MacRootView().environmentObject(app)
                } else {
                    MacRegisterView().environmentObject(app)
                }
            }
            .frame(minWidth: 800, minHeight: 560)
        }
        .windowStyle(.titleBar)
    }
}

/// State of the macOS client: the same core (MsngrCore), protocol and E2EE as iOS.
@MainActor
final class MacAppState: ObservableObject {
    static let httpBase: URL = {
        let fallback = URL(string: "http://localhost:8787")!
        guard let raw = ProcessInfo.processInfo.environment["MSNGR_SERVER"],
              let url = URL(string: raw), url.scheme != nil else { return fallback }
        return url
    }()

    @Published var session: Session?
    private(set) var db: DatabaseQueue!
    private(set) var api: APIClient!
    private(set) var engine: SyncEngine!
    private(set) var e2ee: E2EEManager!
    private(set) var media: MediaManager!
    private(set) var store: IdentityStore!

    struct Session: Codable {
        var userId: String
        var deviceId: String
        var token: String
        var username: String
    }

    private var sessionURL: URL {
        supportDir.appendingPathComponent("session.json")
    }
    private var supportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MsngrMac")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() {
        if let data = try? Data(contentsOf: sessionURL),
           let s = try? JSONDecoder().decode(Session.self, from: data) {
            session = s
            Task { await bootstrap(s) }
        }
    }

    func register(username: String, displayName: String) async throws {
        let db = try AppDatabase.open(at: supportDir.appendingPathComponent("msngr.sqlite"))
        let store = try IdentityStore(db: db, masterKeyProvider: SharedFileMasterKey(containerURL: supportDir))
        let identity = try store.identity()
        let prekeys = try store.generatePrekeys(count: 100)
        let api = APIClient(baseURL: Self.httpBase)
        let reg = try await api.register(.init(
            username: username, displayName: displayName.isEmpty ? username : displayName,
            deviceName: Host.current().localizedName ?? "Mac",
            identityKey: identity.dh.publicKey.rawRepresentation.base64urlEncodedString(),
            identitySignKey: identity.signing.publicKey.rawRepresentation.base64urlEncodedString(),
            identityKeySig: try identity.dhSignature.base64urlEncodedString(),
            signedPrekey: .init(id: prekeys.signedPrekey.id,
                                key: prekeys.signedPrekey.key.publicKey.rawRepresentation.base64urlEncodedString(),
                                sig: prekeys.signedPrekey.signature.base64urlEncodedString()),
            oneTimePrekeys: prekeys.oneTime.map {
                .init(id: $0.id, key: $0.key.publicKey.rawRepresentation.base64urlEncodedString())
            },
            phoneHash: nil))
        let s = Session(userId: reg.userId, deviceId: reg.deviceId, token: reg.token, username: username)
        // a failed write loses the session on the next launch, so don't swallow it
        try JSONEncoder().encode(s).write(to: sessionURL, options: .atomic)
        session = s
        await bootstrap(s)
    }

    private func bootstrap(_ s: Session) async {
        OwnUser.id = s.userId
        MacAppStateHolder.shared = self
        do {
            db = try AppDatabase.open(at: supportDir.appendingPathComponent("msngr.sqlite"))
            api = APIClient(baseURL: Self.httpBase, token: s.token)
            store = try IdentityStore(db: db, masterKeyProvider: SharedFileMasterKey(containerURL: supportDir))
            e2ee = E2EEManager(store: store, api: api, ownUserId: s.userId, ownDeviceId: s.deviceId)
            media = MediaManager(api: api, cacheDir: supportDir.appendingPathComponent("media"))
            var comps = URLComponents(url: Self.httpBase.appendingPathComponent("ws"), resolvingAgainstBaseURL: false)!
            comps.scheme = Self.httpBase.scheme == "https" ? "wss" : "ws"
            comps.queryItems = [URLQueryItem(name: "token", value: s.token)]
            engine = SyncEngine(db: db, api: api, e2ee: e2ee, wsURL: comps.url!,
                                ownUserId: s.userId, ownDeviceId: s.deviceId)
            await engine.start()
            objectWillChange.send()
        } catch {
            print("bootstrap failed: \(error)")
        }
    }

    func logout() {
        try? FileManager.default.removeItem(at: sessionURL)
        session = nil
    }
}

/// userId for background work; the iOS target declares an enum of the same name.
enum OwnUser {
    nonisolated(unsafe) static var id: String = ""
}
