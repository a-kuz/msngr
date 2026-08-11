import XCTest
import GRDB
import MsngrCrypto
@testable import MsngrCore

/// E2E-тест ядра против локального сервера (wrangler dev на :8787).
/// Пропускается, если сервер не поднят.
final class CoreIntegrationTests: XCTestCase {
    static let base = URL(string: "http://localhost:8787")!

    struct TestClient {
        let db: DatabaseQueue
        let api: APIClient
        let e2ee: E2EEManager
        let engine: SyncEngine
        let userId: String
        let deviceId: String
    }

    static func serverUp() async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("api/me"))
        req.timeoutInterval = 2
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse) != nil
        } catch { return false }
    }

    static func makeClient(username: String) async throws -> TestClient {
        let db = try AppDatabase.openInMemory()
        let store = try IdentityStore(db: db, masterKeyProvider: StaticMasterKey())
        let identity = try store.identity()
        let prekeys = try store.generatePrekeys(count: 20)
        let api = APIClient(baseURL: base)
        let reg = try await api.register(.init(
            username: username, displayName: username, deviceName: "test",
            identityKey: identity.dh.publicKey.rawRepresentation.base64urlEncodedString(),
            identitySignKey: identity.signing.publicKey.rawRepresentation.base64urlEncodedString(),
            signedPrekey: .init(id: prekeys.signedPrekey.id,
                                key: prekeys.signedPrekey.key.publicKey.rawRepresentation.base64urlEncodedString(),
                                sig: prekeys.signedPrekey.signature.base64urlEncodedString()),
            oneTimePrekeys: prekeys.oneTime.map {
                .init(id: $0.id, key: $0.key.publicKey.rawRepresentation.base64urlEncodedString())
            },
            phoneHash: nil))
        api.token = reg.token
        let e2ee = E2EEManager(store: store, api: api, ownUserId: reg.userId, ownDeviceId: reg.deviceId)
        var comps = URLComponents(url: base.appendingPathComponent("ws"), resolvingAgainstBaseURL: false)!
        comps.scheme = "ws"
        comps.queryItems = [URLQueryItem(name: "token", value: reg.token)]
        let engine = SyncEngine(db: db, api: api, e2ee: e2ee, wsURL: comps.url!,
                                ownUserId: reg.userId, ownDeviceId: reg.deviceId)
        await engine.start()
        return TestClient(db: db, api: api, e2ee: e2ee, engine: engine,
                          userId: reg.userId, deviceId: reg.deviceId)
    }

    func waitUntil(_ timeout: TimeInterval = 8, _ cond: @escaping () async throws -> Bool) async throws -> Bool {
        let t0 = Date()
        while Date().timeIntervalSince(t0) < timeout {
            if (try? await cond()) == true { return true }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    func testDirectChatE2E() async throws {
        guard await Self.serverUp() else {
            throw XCTSkip("wrangler dev не запущен")
        }
        let suffix = String(UUID().uuidString.prefix(6)).lowercased().replacingOccurrences(of: "-", with: "x")
        let alice = try await Self.makeClient(username: "ca_\(suffix)")
        let bob = try await Self.makeClient(username: "cb_\(suffix)")

        // Алиса создаёт direct-чат и шлёт зашифрованное сообщение
        let chatId = try await alice.api.createChat(kind: "direct", memberIds: [bob.userId], title: nil)
        try await alice.engine.refreshSnapshot()
        var content = ContentPayload(kind: "text")
        content.text = "привет, это e2e"
        try await alice.engine.enqueue(content: content, chatId: chatId)

        // у Алисы сообщение получает seq и статус sent
        let acked = try await waitUntil {
            try await alice.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND seq IS NOT NULL AND status >= 1",
                                 arguments: [chatId]) == 1
            }
        }
        XCTAssertTrue(acked, "ack не пришёл")

        // Боб получает чат и расшифровывает сообщение
        let received = try await waitUntil {
            try await bob.db.read { dbc in
                (try String.fetchOne(dbc, sql: "SELECT text FROM message WHERE chatId = ?",
                                     arguments: [chatId])) == "привет, это e2e"
            }
        }
        XCTAssertTrue(received, "Боб не расшифровал сообщение")

        // чат у Боба помечен как заявка (message request)
        let isRequest = try await bob.db.read { dbc in
            try Bool.fetchOne(dbc, sql: "SELECT isRequest FROM chat WHERE id = ?", arguments: [chatId]) ?? false
        }
        XCTAssertTrue(isRequest, "чат должен быть заявкой до accept")

        // Боб отвечает (после accept) — ratchet в обратную сторону
        try await bob.api.acceptChat(chatId)
        var reply = ContentPayload(kind: "text")
        reply.text = "ответ боба"
        try await bob.engine.enqueue(content: reply, chatId: chatId)

        let gotReply = try await waitUntil {
            try await alice.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND text = 'ответ боба'",
                                 arguments: [chatId]) == 1
            }
        }
        XCTAssertTrue(gotReply, "Алиса не получила ответ")

        // read receipt: Боб читает → у Алисы статус read
        let lastSeq = try await bob.db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT lastSeq FROM chat WHERE id = ?", arguments: [chatId]) ?? 0
        }
        await bob.engine.markRead(chatId: chatId, upToSeq: lastSeq)
        let readMark = try await waitUntil {
            try await alice.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND isOutgoing = 1 AND status = 3",
                                 arguments: [chatId]) ?? 0 >= 1
            }
        }
        XCTAssertTrue(readMark, "read receipt не дошёл")

        await alice.engine.stop()
        await bob.engine.stop()
    }

    func testGroupChatSenderKeys() async throws {
        guard await Self.serverUp() else {
            throw XCTSkip("wrangler dev не запущен")
        }
        let suffix = String(UUID().uuidString.prefix(6)).lowercased().replacingOccurrences(of: "-", with: "x")
        let alice = try await Self.makeClient(username: "ga_\(suffix)")
        let bob = try await Self.makeClient(username: "gb_\(suffix)")
        let carol = try await Self.makeClient(username: "gc_\(suffix)")

        let chatId = try await alice.api.createChat(kind: "group",
                                                    memberIds: [bob.userId, carol.userId],
                                                    title: "Группа")
        try await alice.engine.refreshSnapshot()

        var content = ContentPayload(kind: "text")
        content.text = "групповое сообщение"
        try await alice.engine.enqueue(content: content, chatId: chatId)

        // оба участника расшифровывают через sender key
        for (name, client) in [("bob", bob), ("carol", carol)] {
            let ok = try await waitUntil {
                try await client.db.read { dbc in
                    (try String.fetchOne(dbc, sql: "SELECT text FROM message WHERE chatId = ? AND kind = 'text'",
                                         arguments: [chatId])) == "групповое сообщение"
                }
            }
            XCTAssertTrue(ok, "\(name) не расшифровал групповое сообщение")
        }

        // ответ Боба: его sender key раздаётся, Алиса и Кэрол читают
        var reply = ContentPayload(kind: "text")
        reply.text = "ответ в группе"
        try await bob.engine.enqueue(content: reply, chatId: chatId)
        for (name, client) in [("alice", alice), ("carol", carol)] {
            let ok = try await waitUntil {
                try await client.db.read { dbc in
                    try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND text = 'ответ в группе'",
                                     arguments: [chatId]) == 1
                }
            }
            XCTAssertTrue(ok, "\(name) не получил ответ в группе")
        }

        // реакция: Кэрол ставит ❤️ на сообщение Алисы
        let targetId = try await carol.db.read { dbc in
            try String.fetchOne(dbc, sql: "SELECT msgId FROM message WHERE chatId = ? AND text = 'групповое сообщение'",
                                arguments: [chatId])
        }
        var reaction = ContentPayload(kind: "reaction")
        reaction.targetMsgId = targetId
        reaction.emoji = "❤️"
        try await carol.engine.enqueue(content: reaction, chatId: chatId)
        let reacted = try await waitUntil {
            try await alice.db.read { dbc in
                let r = try String.fetchOne(dbc, sql: "SELECT reactions FROM message WHERE chatId = ? AND msgId = ?",
                                            arguments: [chatId, targetId]) ?? "{}"
                return r.contains("❤️")
            }
        }
        XCTAssertTrue(reacted, "реакция не дошла до Алисы")

        await alice.engine.stop()
        await bob.engine.stop()
        await carol.engine.stop()
    }

    func testOfflineOutboxAndResync() async throws {
        guard await Self.serverUp() else {
            throw XCTSkip("wrangler dev не запущен")
        }
        let suffix = String(UUID().uuidString.prefix(6)).lowercased().replacingOccurrences(of: "-", with: "x")
        let alice = try await Self.makeClient(username: "oa_\(suffix)")
        let bob = try await Self.makeClient(username: "ob_\(suffix)")

        let chatId = try await alice.api.createChat(kind: "direct", memberIds: [bob.userId], title: nil)
        try await alice.engine.refreshSnapshot()

        // Боб уходит в офлайн
        await bob.engine.stop()

        var m1 = ContentPayload(kind: "text"); m1.text = "пока ты офлайн 1"
        var m2 = ContentPayload(kind: "text"); m2.text = "пока ты офлайн 2"
        try await alice.engine.enqueue(content: m1, chatId: chatId)
        try await alice.engine.enqueue(content: m2, chatId: chatId)
        _ = try await waitUntil {
            try await alice.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND seq IS NOT NULL",
                                 arguments: [chatId]) == 2
            }
        }

        // Боб возвращается → sync по курсорам доставляет пропущенное
        await bob.engine.start()
        let caught = try await waitUntil(10) {
            try await bob.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND kind = 'text'",
                                 arguments: [chatId]) == 2
            }
        }
        XCTAssertTrue(caught, "offline-сообщения не доехали после reconnect")

        await alice.engine.stop()
        await bob.engine.stop()
    }
}
