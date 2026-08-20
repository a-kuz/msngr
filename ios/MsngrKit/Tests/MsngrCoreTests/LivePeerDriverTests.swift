import XCTest
import GRDB
import MsngrCrypto
@testable import MsngrCore

/// Driver for a live run against an app on a simulator, not part of the suite:
/// it skips itself unless MSNGR_PEER_TO names the username to write to. It
/// registers a peer, opens a direct chat with that user and sends a real
/// end-to-end encrypted message, which is what the app needs to show a banner,
/// a push or an unread count. The message text comes in MSNGR_PEER_TEXT.
///
/// MSNGR_PEER_HOME keeps the peer: its database and token live in that
/// directory, so the next run is the same person writing again — which is what
/// a scenario past the first message needs, the request having been accepted
/// once.
///
///   MSNGR_PEER_TO=ui123 MSNGR_PEER_HOME=/tmp/peer MSNGR_PEER_TEXT="hi" \
///     swift test --filter LivePeerDriver
final class LivePeerDriverTests: XCTestCase {
    private static let base = URL(string: ProcessInfo.processInfo.environment["MSNGR_TEST_BASE"]
                                  ?? "http://localhost:8787")!

    private struct Account: Codable {
        let token: String
        let userId: String
        let deviceId: String
        let username: String
    }

    func testSendsOneMessageToTheNamedUser() async throws {
        guard let target = ProcessInfo.processInfo.environment["MSNGR_PEER_TO"], !target.isEmpty else {
            throw XCTSkip("live driver; set MSNGR_PEER_TO to the username to write to")
        }
        let text = ProcessInfo.processInfo.environment["MSNGR_PEER_TEXT"] ?? "live banner check"
        let home = ProcessInfo.processInfo.environment["MSNGR_PEER_HOME"].map(URL.init(fileURLWithPath:))
        if let home {
            try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }

        let db = try home.map { try AppDatabase.open(at: $0.appendingPathComponent("peer.sqlite")) }
            ?? AppDatabase.openInMemory()
        // the sealed ratchet state has to open on the next run too, so the key
        // lives beside the database instead of being new every process
        let store = try IdentityStore(db: db, masterKeyProvider: home.map {
            SharedFileMasterKey(containerURL: $0)
        } ?? StaticMasterKey())
        let identity = try store.identity()
        let api = APIClient(baseURL: Self.base)
        let accountURL = home?.appendingPathComponent("account.json")
        let kept = accountURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(Account.self, from: $0) }

        let account: Account
        if let kept {
            account = kept
        } else {
            let prekeys = try store.generatePrekeys(count: 5)
            let suffix = String(UUID().uuidString.prefix(6)).lowercased().replacingOccurrences(of: "-", with: "x")
            let reg = try await api.register(.init(
                username: "peer_\(suffix)", displayName: "Peer \(suffix)", deviceName: "driver",
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
            account = Account(token: reg.token, userId: reg.userId, deviceId: reg.deviceId,
                              username: "peer_\(suffix)")
            if let accountURL, let data = try? JSONEncoder().encode(account) {
                try? data.write(to: accountURL)
            }
        }
        api.token = account.token
        let reg = account

        let found = try await api.searchUsers(target)
        guard let peer = found.first(where: { $0.username == target }) ?? found.first else {
            XCTFail("no user named \(target) on \(Self.base)")
            return
        }
        let chatId = try await api.createChat(kind: "direct", memberIds: [peer.id], title: nil)

        let e2ee = E2EEManager(store: store, api: api, ownUserId: reg.userId, ownDeviceId: reg.deviceId)
        var comps = URLComponents(url: Self.base.appendingPathComponent("ws"),
                                  resolvingAgainstBaseURL: false)!
        comps.scheme = Self.base.scheme == "https" ? "wss" : "ws"
        comps.queryItems = [URLQueryItem(name: "token", value: reg.token)]
        let engine = SyncEngine(db: db, api: api, e2ee: e2ee, wsURL: comps.url!,
                                ownUserId: reg.userId, ownDeviceId: reg.deviceId)
        await engine.start()
        try await engine.refreshSnapshot()
        var content = ContentPayload(kind: "text")
        content.text = text
        try await engine.enqueue(content: content, chatId: chatId)

        // the ack is what says the server took it; the app is on the other side
        var acked = false
        for _ in 0..<80 {
            acked = (try await db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND seq IS NOT NULL",
                                 arguments: [chatId])
            } ?? 0) > 0
            if acked { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        await engine.stop()
        XCTAssertTrue(acked, "the message never got a seq")
        print("sent to \(target) in chat \(chatId) as \(reg.userId)")
    }
}
