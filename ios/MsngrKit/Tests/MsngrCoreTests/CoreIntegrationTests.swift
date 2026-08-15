import XCTest
import GRDB
import MsngrCrypto
@testable import MsngrCore

/// E2E-тест ядра против локального сервера (wrangler dev на :8787).
/// Пропускается, если сервер не поднят.
final class CoreIntegrationTests: XCTestCase {
    /// Адрес dev-сервера; переопределяется переменной окружения MSNGR_TEST_BASE.
    static let base = URL(string: ProcessInfo.processInfo.environment["MSNGR_TEST_BASE"]
                          ?? "http://localhost:8787")!

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

    /// Оба пишут друг другу первыми (одновременная инициация сессии).
    /// Ни одно сообщение не должно потеряться ни у одной стороны.
    func testSimultaneousFirstMessagesBothDecrypt() async throws {
        guard await Self.serverUp() else { throw XCTSkip("wrangler dev не запущен") }
        let suffix = String(UUID().uuidString.prefix(6)).lowercased().replacingOccurrences(of: "-", with: "x")
        let a = try await Self.makeClient(username: "ga_\(suffix)")
        let b = try await Self.makeClient(username: "gb_\(suffix)")

        // A создаёт чат и пишет; B независимо пишет в тот же чат
        let chatId = try await a.api.createChat(kind: "direct", memberIds: [b.userId], title: nil)
        try await a.engine.refreshSnapshot()
        try await b.engine.refreshSnapshot()

        var m1 = ContentPayload(kind: "text"); m1.text = "от A"
        var m2 = ContentPayload(kind: "text"); m2.text = "от B"
        async let s1: Void = a.engine.enqueue(content: m1, chatId: chatId)
        async let s2: Void = b.engine.enqueue(content: m2, chatId: chatId)
        _ = try await (s1, s2)

        let bGotA = try await waitUntil(12) {
            try await b.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND text = 'от A'",
                                 arguments: [chatId]) == 1
            }
        }
        let aGotB = try await waitUntil(12) {
            try await a.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND text = 'от B'",
                                 arguments: [chatId]) == 1
            }
        }
        XCTAssertTrue(bGotA, "B не расшифровал сообщение A")
        XCTAssertTrue(aGotB, "A не расшифровал сообщение B")

        // и дальше переписка продолжается в обе стороны
        var m3 = ContentPayload(kind: "text"); m3.text = "ответ A"
        try await a.engine.enqueue(content: m3, chatId: chatId)
        let bGotReply = try await waitUntil(12) {
            try await b.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND text = 'ответ A'",
                                 arguments: [chatId]) == 1
            }
        }
        XCTAssertTrue(bGotReply, "переписка развалилась после встречной инициации")

        // ни одного нечитаемого на обеих сторонах: ни отложенного конверта,
        // ни записи о пропавшем seq
        for (name, c) in [("A", a), ("B", b)] {
            let bad = try await c.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM pendingDecrypt")! +
                    Int.fetchOne(dbc, sql: """
                        SELECT COUNT(*) FROM historyGap WHERE reason NOT IN ('service','sender_key')
                        """)!
            }
            XCTAssertEqual(bad, 0, "у \(name) есть нечитаемые сообщения")
        }

        await a.engine.stop()
        await b.engine.stop()
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

        // forward secrecy: удаляем Кэрол, Алиса ротирует sender key и шлёт новое.
        // Боб читает, Кэрол — уже нет.
        try await alice.api.updateMembers(chatId, add: [], remove: [carol.userId])
        _ = try await waitUntil {
            try await alice.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM member WHERE chatId = ? AND userId = ?",
                                 arguments: [chatId, carol.userId]) == 0
            }
        }
        var after = ContentPayload(kind: "text")
        after.text = "после удаления Кэрол"
        try await alice.engine.enqueue(content: after, chatId: chatId)
        let bobGot = try await waitUntil {
            try await bob.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND text = 'после удаления Кэрол'",
                                 arguments: [chatId]) == 1
            }
        }
        XCTAssertTrue(bobGot, "Боб должен получить сообщение после ротации")
        // дать времени на возможную (нежелательную) доставку Кэрол
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let carolLeaked = try await carol.db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND text = 'после удаления Кэрол'",
                             arguments: [chatId]) ?? 0
        }
        XCTAssertEqual(carolLeaked, 0, "удалённый участник не должен читать новые сообщения")

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

    /// Состояние сессии у получателя испорчено: ни один конверт отправителя
    /// больше не открывается. Устройство чинит это само — просит копию, поднимает
    /// сессию заново и ставит сообщение в ленту под исходным msgId, без дубля.
    func testCorruptedSessionIsRepairedThroughSender() async throws {
        guard await Self.serverUp() else {
            throw XCTSkip("wrangler dev не запущен")
        }
        let suffix = String(UUID().uuidString.prefix(6)).lowercased().replacingOccurrences(of: "-", with: "x")
        let alice = try await Self.makeClient(username: "ra_\(suffix)")
        let bob = try await Self.makeClient(username: "rb_\(suffix)")

        let chatId = try await alice.api.createChat(kind: "direct", memberIds: [bob.userId], title: nil)
        try await alice.engine.refreshSnapshot()
        var first = ContentPayload(kind: "text")
        first.text = "до поломки"
        try await alice.engine.enqueue(content: first, chatId: chatId)
        let gotFirst = try await waitUntil {
            try await bob.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND text = 'до поломки'",
                                 arguments: [chatId]) == 1
            }
        }
        XCTAssertTrue(gotFirst, "первое сообщение не доехало")
        // до принятия заявки ремонт молчит: он выдал бы автору, что получатель
        // на месте. Дальше чат обычный
        try await bob.api.acceptChat(chatId)
        try await bob.engine.refreshSnapshot()

        // состояние сессии Боба подменяется мусором: расшифровать нечем
        try await bob.db.write { dbc in
            try dbc.execute(sql: "UPDATE ratchetSession SET state = ?, archived = NULL",
                            arguments: [Data(repeating: 0x7f, count: 48)])
        }

        var lost = ContentPayload(kind: "text")
        lost.text = "после поломки"
        try await alice.engine.enqueue(content: lost, chatId: chatId)
        let recorded = try await waitUntil {
            try await bob.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM pendingDecrypt WHERE chatId = ?",
                                 arguments: [chatId]) == 1
            }
        }
        XCTAssertTrue(recorded, "нечитаемый конверт не сохранён")
        let keptEnvelope = try await bob.db.read { dbc in
            (try Row.fetchOne(dbc, sql: "SELECT body FROM pendingDecrypt")?["body"] as Data?) ?? Data()
        }
        XCTAssertFalse(keptEnvelope.isEmpty, "конверт сохранён пустым — повторить нечем")

        // срок ожидания ключа выдержан → проход просит копию у отправителя
        try await bob.db.write { dbc in
            try dbc.execute(sql: "UPDATE pendingDecrypt SET firstSeenAt = ?, lastTriedAt = 0",
                            arguments: [Date().timeIntervalSince1970 - MessageRepair.repairGrace - 1])
        }
        await bob.engine.sweepUnreadable()

        let repaired = try await waitUntil(15) {
            try await bob.db.read { dbc in
                try String.fetchOne(dbc, sql: "SELECT text FROM message WHERE chatId = ? AND text = 'после поломки'",
                                    arguments: [chatId]) != nil
            }
        }
        XCTAssertTrue(repaired, "сообщение не починилось")

        // ровно одна строка на сообщение и ни одной записи о пропаже
        let rows = try await bob.db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND text = 'после поломки'",
                             arguments: [chatId])!
        }
        XCTAssertEqual(rows, 1, "починенное сообщение продублировалось")
        let leftovers = try await bob.db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM pendingDecrypt")! +
                Int.fetchOne(dbc, sql: """
                    SELECT COUNT(*) FROM historyGap WHERE reason NOT IN ('service','sender_key')
                    """)!
        }
        XCTAssertEqual(leftovers, 0, "после починки остались следы пропажи")

        // сессия поднята заново: следующее сообщение читается без ремонта
        var after = ContentPayload(kind: "text")
        after.text = "после починки"
        try await alice.engine.enqueue(content: after, chatId: chatId)
        let flows = try await waitUntil(10) {
            try await bob.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND text = 'после починки'",
                                 arguments: [chatId]) == 1
            }
        }
        XCTAssertTrue(flows, "переписка не восстановилась после ремонта")

        await alice.engine.stop()
        await bob.engine.stop()
    }
}
