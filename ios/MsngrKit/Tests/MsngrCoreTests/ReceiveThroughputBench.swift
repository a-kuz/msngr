import XCTest
import GRDB
import MsngrCrypto
@testable import MsngrCore

/// Ingest throughput of the receiving side, measured against a live dev server.
///
/// The sender goes first and the receiver is offline, so the run times the
/// receiver alone: it comes back to a full journal and the catch-up drives the
/// same frame path a live burst does. `MSNGR_BENCH_HISTORY` preloads the
/// receiver's chat with rows before the run, which is how the rate is compared
/// at a comparable history size.
///
/// Off by default — it needs a server and takes minutes. Run it with:
///   MSNGR_BENCH=1 MSNGR_TEST_BASE=http://localhost:8853 \
///   swift test --filter ReceiveThroughputBench
final class ReceiveThroughputBench: XCTestCase {
    static var base: URL {
        URL(string: ProcessInfo.processInfo.environment["MSNGR_TEST_BASE"]
            ?? "http://localhost:8787")!
    }
    static var messageCount: Int {
        Int(ProcessInfo.processInfo.environment["MSNGR_BENCH_COUNT"] ?? "") ?? 1000
    }
    static var historyRows: Int {
        Int(ProcessInfo.processInfo.environment["MSNGR_BENCH_HISTORY"] ?? "") ?? 0
    }

    struct Client {
        let db: DatabaseQueue
        let api: APIClient
        let e2ee: E2EEManager
        var engine: SyncEngine
        let userId: String
        let deviceId: String
        let token: String
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msngr-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// A client on a real file database: the write cost of the receive path is
    /// what the run measures, and an in-memory queue does not pay it.
    private func makeClient(_ username: String) async throws -> Client {
        let db = try AppDatabase.open(at: tempDir.appendingPathComponent("\(username).sqlite"))
        let store = try IdentityStore(db: db, masterKeyProvider: StaticMasterKey())
        let identity = try store.identity()
        let prekeys = try store.generatePrekeys(count: 20)
        let api = APIClient(baseURL: Self.base)
        let reg = try await api.register(.init(
            username: username, displayName: username, deviceName: "bench",
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
        let engine = SyncEngine(db: db, api: api, e2ee: e2ee, wsURL: Self.wsURL(token: reg.token),
                                ownUserId: reg.userId, ownDeviceId: reg.deviceId)
        await engine.start()
        return Client(db: db, api: api, e2ee: e2ee, engine: engine,
                      userId: reg.userId, deviceId: reg.deviceId, token: reg.token)
    }

    private static func wsURL(token: String) -> URL {
        var comps = URLComponents(url: base.appendingPathComponent("ws"), resolvingAgainstBaseURL: false)!
        comps.scheme = "ws"
        comps.queryItems = [URLQueryItem(name: "token", value: token)]
        return comps.url!
    }

    private func restart(_ c: Client) async -> SyncEngine {
        let engine = SyncEngine(db: c.db, api: c.api, e2ee: c.e2ee, wsURL: Self.wsURL(token: c.token),
                                ownUserId: c.userId, ownDeviceId: c.deviceId)
        await engine.start()
        return engine
    }

    private func waitUntil(_ timeout: TimeInterval, _ cond: @escaping () async throws -> Bool) async throws -> Bool {
        let t0 = Date()
        while Date().timeIntervalSince(t0) < timeout {
            if (try? await cond()) == true { return true }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    /// History the receiver already holds when the burst lands. The seqs sit far
    /// above the live range so the rows weigh on the tables without colliding
    /// with anything the run delivers.
    private func preloadHistory(_ c: Client, chatId: String, rows: Int) async throws {
        guard rows > 0 else { return }
        try await c.db.write { dbc in
            for i in 0..<rows {
                var m = Message(id: "pre-\(i)", chatId: chatId, fromUserId: c.userId,
                                sentAt: Date().timeIntervalSince1970 - Double(rows - i),
                                kind: .text, text: "history \(i)", status: .sent, isOutgoing: true)
                m.seq = 1_000_000 + i
                m.serverTs = m.sentAt
                try m.save(dbc)
            }
        }
    }

    // MARK: - Provisioning a pair for a simulator run

    /// Registers two accounts into `MSNGR_PROVISION_DIR/{alice,bob}` in the file
    /// layout the app boots from, opens a direct chat between them and lets the
    /// receiver accept it. Copying one of the directories into a simulator's app
    /// group container gives a logged-in app without going through the
    /// registration screen.
    func testProvisionPair() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MSNGR_PROVISION_DIR"] else {
            throw XCTSkip("provisioning runs only with MSNGR_PROVISION_DIR set")
        }
        let root = URL(fileURLWithPath: dir)
        let suffix = String(UUID().uuidString.prefix(6)).lowercased()
        // a fixed name for the sender lets a stand of one's own carry the
        // account the UI smoke opens a chat with
        let aliceName = ProcessInfo.processInfo.environment["MSNGR_PROVISION_SENDER"] ?? "pa_\(suffix)"
        let alice = try await provision(at: root.appendingPathComponent("alice"), username: aliceName)
        let bob = try await provision(at: root.appendingPathComponent("bob"), username: "pb_\(suffix)")

        let chatId = try await alice.api.createChat(kind: "direct", memberIds: [bob.userId], title: nil)
        try await alice.engine.refreshSnapshot()
        var hello = ContentPayload(kind: "text")
        hello.text = "hello"
        try await alice.engine.enqueue(content: hello, chatId: chatId)
        let opened = try await waitUntil(30) {
            try await bob.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ?",
                                 arguments: [chatId]) == 1
            }
        }
        XCTAssertTrue(opened, "the first message never arrived")
        try await bob.api.acceptChat(chatId)
        try await bob.engine.refreshSnapshot()
        try await alice.engine.refreshSnapshot()

        try Data(chatId.utf8).write(to: root.appendingPathComponent("chatid.txt"))
        await alice.engine.stop()
        await bob.engine.stop()
        print("PROVISIONED chat=\(chatId) alice=\(alice.userId) bob=\(bob.userId)")
    }

    /// Sends a burst from the account provisioned in `MSNGR_PROVISION_DIR/alice`
    /// into the chat recorded next to it. The receiver is a simulator running the
    /// app, so nothing here waits on it.
    func testSendBurst() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MSNGR_PROVISION_DIR"] else {
            throw XCTSkip("the burst runs only with MSNGR_PROVISION_DIR set")
        }
        let root = URL(fileURLWithPath: dir)
        let chatId = try String(contentsOf: root.appendingPathComponent("chatid.txt"), encoding: .utf8)
        let alice = try await reopen(at: root.appendingPathComponent("alice"))
        let total = Self.messageCount
        let t0 = Date()
        for i in 1...total {
            var m = ContentPayload(kind: "text")
            m.text = "Test message \(i) of \(total)"
            try await alice.engine.enqueue(content: m, chatId: chatId)
        }
        // the queue is what says the burst is out: every row it held is either
        // acknowledged or gave up, and nothing is left to send
        let acked = try await waitUntil(Double(total) / 3 + 300) {
            try await alice.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM outbox")! == 0
            }
        }
        let seconds = Date().timeIntervalSince(t0)
        print("BURST sent=\(total) acked=\(acked) rate=\(String(format: "%.1f", Double(total) / seconds))/s")
        await alice.engine.stop()
    }

    private struct Provisioned {
        let db: DatabaseQueue
        let api: APIClient
        let engine: SyncEngine
        let userId: String
    }

    private func provision(at root: URL, username: String) async throws -> Provisioned {
        let location = StorageLocation(root: root)
        try AppContainer.prepare(location)
        let db = try AppDatabase.open(at: location.databaseURL)
        let store = try IdentityStore(db: db, masterKeyProvider: SharedFileMasterKey(location: location))
        let identity = try store.identity()
        let prekeys = try store.generatePrekeys(count: 20)
        let api = APIClient(baseURL: Self.base)
        let reg = try await api.register(.init(
            username: username, displayName: username, deviceName: "bench",
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
        let session = ["userId": reg.userId, "deviceId": reg.deviceId,
                       "token": reg.token, "username": username]
        try JSONSerialization.data(withJSONObject: session).write(to: location.sessionURL)
        let e2ee = E2EEManager(store: store, api: api, ownUserId: reg.userId, ownDeviceId: reg.deviceId)
        let engine = SyncEngine(db: db, api: api, e2ee: e2ee, wsURL: Self.wsURL(token: reg.token),
                                ownUserId: reg.userId, ownDeviceId: reg.deviceId)
        await engine.start()
        return Provisioned(db: db, api: api, engine: engine, userId: reg.userId)
    }

    private func reopen(at root: URL) async throws -> Provisioned {
        let location = StorageLocation(root: root)
        let session = try JSONSerialization.jsonObject(
            with: Data(contentsOf: location.sessionURL)) as! [String: String]
        let db = try AppDatabase.open(at: location.databaseURL)
        let store = try IdentityStore(db: db, masterKeyProvider: SharedFileMasterKey(location: location))
        let api = APIClient(baseURL: Self.base, token: session["token"])
        let e2ee = E2EEManager(store: store, api: api, ownUserId: session["userId"]!,
                               ownDeviceId: session["deviceId"]!)
        let engine = SyncEngine(db: db, api: api, e2ee: e2ee, wsURL: Self.wsURL(token: session["token"]!),
                                ownUserId: session["userId"]!, ownDeviceId: session["deviceId"]!)
        await engine.start()
        return Provisioned(db: db, api: api, engine: engine, userId: session["userId"]!)
    }

    func testReceiveThroughput() async throws {
        guard ProcessInfo.processInfo.environment["MSNGR_BENCH"] != nil else {
            throw XCTSkip("benchmark runs only with MSNGR_BENCH set")
        }
        let total = Self.messageCount
        let suffix = String(UUID().uuidString.prefix(6)).lowercased()
        let alice = try await makeClient("ba_\(suffix)")
        var bob = try await makeClient("bb_\(suffix)")

        let chatId = try await alice.api.createChat(kind: "direct", memberIds: [bob.userId], title: nil)
        try await alice.engine.refreshSnapshot()
        var hello = ContentPayload(kind: "text")
        hello.text = "hello"
        try await alice.engine.enqueue(content: hello, chatId: chatId)
        let opened = try await waitUntil(30) {
            try await bob.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ?",
                                 arguments: [chatId]) == 1
            }
        }
        XCTAssertTrue(opened, "the first message never arrived")
        try await bob.api.acceptChat(chatId)
        try await bob.engine.refreshSnapshot()

        // the receiver is offline while the whole burst is written to the journal
        await bob.engine.stop()
        try await preloadHistory(bob, chatId: chatId, rows: Self.historyRows)

        let sendStart = Date()
        for i in 1...total {
            var m = ContentPayload(kind: "text")
            m.text = "Test message \(i) of \(total)"
            try await alice.engine.enqueue(content: m, chatId: chatId)
        }
        let acked = try await waitUntil(Double(total) / 5 + 120) {
            try await alice.db.read { dbc in
                try Int.fetchOne(dbc, sql: """
                    SELECT COUNT(*) FROM message WHERE chatId = ? AND seq IS NOT NULL
                    """, arguments: [chatId]) == total + 1
            }
        }
        XCTAssertTrue(acked, "the sender did not get every ack")
        let sendSeconds = Date().timeIntervalSince(sendStart)

        // the receiver comes back and drains the journal: this is the measurement
        let baseline = try await bob.db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ?",
                             arguments: [chatId])!
        }
        let target = baseline + total
        let recvStart = Date()
        bob.engine = await restart(bob)
        var samples: [(t: Double, rows: Int)] = []
        var done = false
        while Date().timeIntervalSince(recvStart) < Double(total) + 600 {
            let rows = try await bob.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ?",
                                 arguments: [chatId])!
            }
            samples.append((Date().timeIntervalSince(recvStart), rows))
            if rows >= target { done = true; break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        let recvSeconds = Date().timeIntervalSince(recvStart)
        XCTAssertTrue(done, "catch-up did not finish: \(samples.last?.rows ?? 0) of \(target)")

        print("""
        BENCH history=\(Self.historyRows) count=\(total) \
        send=\(String(format: "%.1f", Double(total) / sendSeconds))/s \
        recv=\(String(format: "%.1f", Double(total) / recvSeconds))/s \
        recvSeconds=\(String(format: "%.1f", recvSeconds))
        """)
        for s in samples {
            print("BENCHPOINT t=\(String(format: "%.1f", s.t)) rows=\(s.rows)")
        }

        await alice.engine.stop()
        await bob.engine.stop()
    }
}
