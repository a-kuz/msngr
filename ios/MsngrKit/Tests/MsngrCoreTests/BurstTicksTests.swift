import XCTest
import GRDB
import MsngrCrypto
@testable import MsngrCore

/// A burst of a hundred messages between two live clients, judged by what the
/// author sees: every message on the recipient's side, and every tick under it
/// moving when that message arrives rather than once the burst is over.
///
/// Runs against a dev server (`MSNGR_TEST_BASE`, wrangler dev), and skips itself
/// when nothing answers there. The clients keep their databases in files: the
/// receive path pays for a write and for the ratchet step under `CryptoGate`,
/// and an in-memory queue pays neither.
final class BurstTicksTests: XCTestCase {
    static let base = URL(string: ProcessInfo.processInfo.environment["MSNGR_TEST_BASE"]
                          ?? "http://localhost:8787")!
    /// Messages in the burst. A hundred is the owner's scenario.
    static var count: Int { Int(ProcessInfo.processInfo.environment["MSNGR_BURST_COUNT"] ?? "") ?? 100 }
    /// The whole burst has to be on the recipient's side inside this.
    static let landLimit: TimeInterval = 10
    /// How far the author's ticks may trail the arrivals they answer. The bar is
    /// per message, not for the burst: the tick under message k moves when
    /// message k is there, whatever is still in flight behind it.
    static let tickLagLimit: TimeInterval = 2

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msngr-burst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    struct Client {
        let db: DatabaseQueue
        let api: APIClient
        let engine: SyncEngine
        let userId: String
        let deviceId: String
    }

    private static func serverUp() async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("api/me"))
        req.timeoutInterval = 2
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse) != nil
        } catch { return false }
    }

    private func makeClient(_ username: String) async throws -> Client {
        let db = try AppDatabase.open(at: tempDir.appendingPathComponent("\(username).sqlite"))
        let store = try IdentityStore(db: db, masterKeyProvider: StaticMasterKey())
        let identity = try store.identity()
        let prekeys = try store.generatePrekeys(count: 20)
        let api = APIClient(baseURL: Self.base)
        let reg = try await api.register(.init(
            username: username, displayName: username, deviceName: "burst",
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
        api.token = reg.token
        let e2ee = E2EEManager(store: store, api: api, ownUserId: reg.userId, ownDeviceId: reg.deviceId)
        var comps = URLComponents(url: Self.base.appendingPathComponent("ws"),
                                  resolvingAgainstBaseURL: false)!
        comps.scheme = "ws"
        comps.queryItems = [URLQueryItem(name: "token", value: reg.token)]
        let engine = SyncEngine(db: db, api: api, e2ee: e2ee, wsURL: comps.url!,
                                ownUserId: reg.userId, ownDeviceId: reg.deviceId)
        await engine.start()
        return Client(db: db, api: api, engine: engine, userId: reg.userId, deviceId: reg.deviceId)
    }

    private func waitUntil(_ timeout: TimeInterval, _ cond: @escaping () async throws -> Bool) async throws -> Bool {
        let t0 = Date()
        while Date().timeIntervalSince(t0) < timeout {
            if (try? await cond()) == true { return true }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// A burst is not paced, and its ticks are not postponed to its end.
    func testBurstLandsAtOnceAndEveryTickFollowsItsMessage() async throws {
        guard await Self.serverUp() else { throw XCTSkip("no dev server on \(Self.base)") }
        let total = Self.count
        let suffix = String(UUID().uuidString.prefix(6)).lowercased()
        let alice = try await makeClient("bta_\(suffix)")
        let bob = try await makeClient("btb_\(suffix)")
        defer { Task { await alice.engine.stop(); await bob.engine.stop() } }
        // A device in a burst has a push token, and a push is raised for every
        // content message whatever the socket is doing. Whether APNs is fast,
        // slow or not there at all is none of the chat's business: the token is
        // registered here so a run says so.
        try await bob.api.registerPushToken("burst-\(suffix)", env: "sandbox")

        let chatId = try await alice.api.createChat(kind: "direct", memberIds: [bob.userId], title: nil)
        try await alice.engine.refreshSnapshot()
        // the recipient of an unaccepted request owes no receipts at all, so the
        // burst is measured on a chat that is already a conversation
        var hello = ContentPayload(kind: "text")
        hello.text = "hello"
        try await alice.engine.enqueue(content: hello, chatId: chatId)
        let opened = try await waitUntil(30) {
            try await bob.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ?",
                                 arguments: [chatId]) == 1
            }
        }
        XCTAssertTrue(opened, "the chat never opened on the recipient")
        try await bob.api.acceptChat(chatId)
        try await bob.engine.refreshSnapshot()
        let acceptedTicks = try await waitUntil(15) {
            try await alice.db.read { dbc in
                try Int.fetchOne(dbc, sql: """
                    SELECT COUNT(*) FROM message WHERE chatId = ? AND isOutgoing = 1 AND status >= 2
                    """, arguments: [chatId]) == 1
            }
        }
        XCTAssertTrue(acceptedTicks, "the first message never earned its tick")

        let t0 = Date()
        for i in 1...total {
            var m = ContentPayload(kind: "text")
            m.text = "burst \(i) of \(total)"
            try await alice.engine.enqueue(content: m, chatId: chatId)
        }
        let queued = Date().timeIntervalSince(t0)

        // The two curves the run is about: how many the recipient holds, and how
        // many of them the author has a second tick for. Sampled together, so a
        // tick that waits for the end of the burst is a gap between them.
        var landedAt: [Double] = []   // landedAt[k] = when the recipient held k+1 of the burst
        var tickedAt: [Double] = []
        let deadline = t0.addingTimeInterval(Self.landLimit + Self.tickLagLimit + 60)
        while Date() < deadline {
            let got = try await bob.db.read { dbc in
                try Int.fetchOne(dbc, sql: """
                    SELECT COUNT(*) FROM message WHERE chatId = ? AND isOutgoing = 0 AND text LIKE 'burst %'
                    """, arguments: [chatId]) ?? 0
            }
            let ticked = try await alice.db.read { dbc in
                try Int.fetchOne(dbc, sql: """
                    SELECT COUNT(*) FROM message
                    WHERE chatId = ? AND isOutgoing = 1 AND status >= 2 AND text LIKE 'burst %'
                    """, arguments: [chatId]) ?? 0
            }
            let now = Date().timeIntervalSince(t0)
            while landedAt.count < got { landedAt.append(now) }
            while tickedAt.count < ticked { tickedAt.append(now) }
            if got >= total && ticked >= total { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let landMs = landedAt.last.map { Int($0 * 1000) } ?? -1
        let lags = (0..<min(landedAt.count, tickedAt.count)).map { tickedAt[$0] - landedAt[$0] }
        let worstLag = lags.max() ?? .infinity
        let gaps = zip(landedAt.dropFirst(), landedAt).map { ($0 - $1) * 1000 }
        print("""
        BURST total=\(total) queued=\(Int(queued * 1000))ms \
        landed=\(landedAt.count)/\(total) in \(landMs)ms \
        gap(mean)=\(Int(gaps.isEmpty ? 0 : gaps.reduce(0, +) / Double(gaps.count)))ms \
        gap(max)=\(Int(gaps.max() ?? 0))ms \
        ticked=\(tickedAt.count)/\(total) lag(max)=\(Int(worstLag * 1000))ms
        """)

        XCTAssertEqual(landedAt.count, total, "the recipient is short of the burst")
        XCTAssertEqual(tickedAt.count, total, "messages the author has no second tick for")
        XCTAssertLessThan(Double(landMs) / 1000, Self.landLimit,
                          "the burst was paced out instead of landing at once")
        XCTAssertLessThan(worstLag, Self.tickLagLimit,
                          "a tick waited for the burst to end instead of following its message")
    }
}
