import XCTest
import GRDB
import MsngrCrypto
@testable import MsngrCore

/// Ремонт нечитаемых сообщений: конверт сохраняется при любом отказе, очередь
/// переигрывается сама, а то, что переиграть нельзя, запрашивается у отправителя.
/// Сервер не нужен — движок создаётся с недоступным адресом, отправка копится
/// в outbox.
final class MessageRepairTests: XCTestCase {
    private func makeEngine(db: DatabaseQueue) throws -> SyncEngine {
        let api = APIClient(baseURL: URL(string: "http://localhost:1")!)
        let store = try IdentityStore(db: db, masterKeyProvider: StaticMasterKey())
        let e2ee = E2EEManager(store: store, api: api, ownUserId: "me", ownDeviceId: "dev")
        return SyncEngine(db: db, api: api, e2ee: e2ee,
                          wsURL: URL(string: "ws://localhost:1/ws")!,
                          ownUserId: "me", ownDeviceId: "dev")
    }

    private func makeDirectChat(_ db: DatabaseQueue) async throws {
        try await db.write { dbc in
            try dbc.execute(sql: "INSERT INTO chat (id, kind, createdBy, createdAt) VALUES ('c1','direct','peer',0)")
            try dbc.execute(sql: "INSERT INTO member (chatId, userId, role, joinedAt) VALUES ('c1','me','member',0)")
            try dbc.execute(sql: "INSERT INTO member (chatId, userId, role, joinedAt) VALUES ('c1','peer','member',0)")
        }
    }

    /// Конверт, который эта сессия не откроет никогда (неизвестный режим).
    private func brokenFrame(seq: Int, msgId: String) throws -> WSIncoming {
        let json = """
        {"t":"msg","chatId":"c1","seq":\(seq),"msgId":"\(msgId)","from":"peer","fromDevice":"d1",
        "sentAt":1,"ts":1,"body":{"v":1,"mode":"zz"}}
        """
        return try JSONDecoder().decode(WSIncoming.self, from: Data(json.utf8))
    }

    private func outboxContents(_ db: DatabaseQueue) async throws -> [(id: String, content: ContentPayload)] {
        try await db.read { dbc in
            try Row.fetchAll(dbc, sql: "SELECT clientMsgId, payload FROM outbox ORDER BY createdAt")
                .compactMap { row in
                    guard let c = try? JSONDecoder().decode(ContentPayload.self, from: row["payload"] as Data)
                    else { return nil }
                    return (row["clientMsgId"] as String, c)
                }
        }
    }

    // MARK: - Сохранение конверта и запрос копии

    /// Неустранимый отказ: конверт остаётся в базе (повторить локально есть чем),
    /// seq записан как пропавший, отправителю уходит запрос копии.
    func testTerminalFailureKeepsEnvelopeAndAsksSender() async throws {
        let db = try AppDatabase.openInMemory()
        try await makeDirectChat(db)
        let engine = try makeEngine(db: db)

        await engine.apply(try brokenFrame(seq: 1, msgId: "m1"))

        let pending = try await db.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT * FROM pendingDecrypt WHERE chatId = 'c1' AND msgId = 'm1'")
        }
        let row = try XCTUnwrap(pending, "конверт не сохранён — повторить нечем")
        XCTAssertFalse((row["body"] as Data).isEmpty)
        XCTAssertEqual(row["reason"] as String?, "unknown_mode")
        XCTAssertEqual(row["repairAttempts"] as Int, 1)

        let gap = try await db.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT * FROM historyGap WHERE chatId = 'c1' AND seq = 1")
        }
        XCTAssertEqual(try XCTUnwrap(gap)["reason"] as String?, "unknown_mode")

        let outbox = try await outboxContents(db)
        XCTAssertEqual(outbox.count, 1)
        XCTAssertEqual(outbox[0].id, MessageRepair.requestId(msgId: "m1", attempt: 1))
        XCTAssertEqual(outbox[0].content.kind, "repairRequest")
        XCTAssertEqual(outbox[0].content.to, "peer")
        XCTAssertEqual(outbox[0].content.targetMsgId, "m1")
        XCTAssertEqual(outbox[0].content.repairSeq, 1)
        XCTAssertEqual(outbox[0].content.attempt, 1)
    }

    /// Пропущенный ключ сам по себе ещё не дефект: конверт откладывается,
    /// отправителя не беспокоим, пока не выйдет срок ожидания.
    func testRetryableFailureWaitsBeforeAsking() async throws {
        let db = try AppDatabase.openInMemory()
        try await makeDirectChat(db)
        let engine = try makeEngine(db: db)

        let json = """
        {"t":"msg","chatId":"c1","seq":1,"msgId":"m1","from":"peer","fromDevice":"d1",
        "sentAt":1,"ts":1,"body":{"v":1,"mode":"skm","c":"AA==","keyId":"k1","iteration":0,"sig":"AA=="}}
        """
        await engine.apply(try JSONDecoder().decode(WSIncoming.self, from: Data(json.utf8)))

        let row = try await db.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT * FROM pendingDecrypt WHERE chatId = 'c1' AND msgId = 'm1'")
        }
        XCTAssertEqual(try XCTUnwrap(row)["reason"] as String?, "no_sender_key")
        XCTAssertEqual(try XCTUnwrap(row)["repairAttempts"] as Int, 0)
        let outbox = try await outboxContents(db)
        XCTAssertTrue(outbox.isEmpty, "запрос ушёл раньше срока ожидания ключа")
    }

    /// Отложенная очередь переигрывается при старте движка, а не только после
    /// удачного фрейма в том же чате: иначе запись ждёт вечно.
    func testQueueIsSweptOnStart() async throws {
        let db = try AppDatabase.openInMemory()
        try await makeDirectChat(db)
        let old = Date().timeIntervalSince1970 - 3600
        try await db.write { dbc in
            try dbc.execute(
                sql: """
                INSERT INTO pendingDecrypt (chatId, msgId, seq, fromUserId, fromDevice, sentAt, ts,
                                            body, reason, attempts, firstSeenAt, lastTriedAt)
                VALUES ('c1','m1',1,'peer','d1',1,1,?,'no_session',1,?,?)
                """,
                arguments: [Data(#"{"v":1,"mode":"zz"}"#.utf8), old, old])
        }

        let engine = try makeEngine(db: db)
        await engine.start()
        defer { Task { await engine.stop() } }

        var attempts = 0
        for _ in 0..<50 {
            attempts = try await db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT attempts FROM pendingDecrypt WHERE msgId = 'm1'") ?? 0
            }
            if attempts > 1 { break }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        XCTAssertGreaterThan(attempts, 1, "очередь при старте не переигрывалась")

        var outbox = try await outboxContents(db)
        for _ in 0..<50 where outbox.isEmpty {
            try await Task.sleep(nanoseconds: 40_000_000)
            outbox = try await outboxContents(db)
        }
        XCTAssertEqual(outbox.first?.content.kind, "repairRequest")
    }

    /// Счётчик попыток растёт и ограничивает повторы: после исчерпания движок
    /// перестаёт просить копию, сколько бы проходов ни было.
    func testAttemptsGrowAndCapRepeats() async throws {
        let db = try AppDatabase.openInMemory()
        try await makeDirectChat(db)
        let engine = try makeEngine(db: db)

        await engine.apply(try brokenFrame(seq: 1, msgId: "m1"))
        // каждый проход застаёт паузу выдержанной, а конверт — нестарым
        for _ in 0..<(MessageRepair.maxAttempts + 3) {
            try await db.write { dbc in
                try dbc.execute(sql: """
                    UPDATE pendingDecrypt SET lastTriedAt = 0, repairAskedAt = 0,
                      firstSeenAt = ? WHERE msgId = 'm1'
                    """, arguments: [Date().timeIntervalSince1970])
            }
            await engine.sweepUnreadable()
        }

        let row = try await db.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT * FROM pendingDecrypt WHERE msgId = 'm1'")
        }
        let pending = try XCTUnwrap(row)
        XCTAssertEqual(pending["repairAttempts"] as Int, MessageRepair.maxAttempts)
        XCTAssertGreaterThan(pending["attempts"] as Int, MessageRepair.maxAttempts)

        let outbox = try await outboxContents(db)
        XCTAssertEqual(outbox.count, MessageRepair.maxAttempts,
                       "запросов больше, чем разрешено попыток")

        // потраченные попытки доводят seq до заглушки в ленте
        let shown = try await db.read { dbc in
            try HistoryWindow.exhaustedGapSeqs(dbc, chatId: "c1", floor: nil)
        }
        XCTAssertEqual(shown, [1])
    }

    /// Конверт с исчерпанными попытками и вышедшим сроком забывается, но запись
    /// о пропавшем seq остаётся: пагинация не пойдёт за ним на сервер снова.
    func testExpiredEnvelopeIsDroppedAndSeqStaysRecorded() async throws {
        let db = try AppDatabase.openInMemory()
        try await makeDirectChat(db)
        let engine = try makeEngine(db: db)

        await engine.apply(try brokenFrame(seq: 1, msgId: "m1"))
        try await db.write { dbc in
            try dbc.execute(sql: """
                UPDATE pendingDecrypt SET repairAttempts = ?, firstSeenAt = ? WHERE msgId = 'm1'
                """, arguments: [MessageRepair.maxAttempts,
                                 Date().timeIntervalSince1970 - MessageRepair.envelopeTTL - 1])
        }
        await engine.sweepUnreadable()

        let left = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM pendingDecrypt")!
        }
        XCTAssertEqual(left, 0)
        let gap = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM historyGap WHERE chatId = 'c1' AND seq = 1")!
        }
        XCTAssertEqual(gap, 1)
    }

    // MARK: - Сторона отправителя

    /// Запрос копии: сообщение есть в локальной базе отправителя — оно уезжает
    /// адресату заново, с исходным msgId.
    func testSenderAnswersWithOriginalContent() async throws {
        let db = try AppDatabase.openInMemory()
        try await makeDirectChat(db)
        let engine = try makeEngine(db: db)
        try await db.write { dbc in
            var msg = Message(id: "local1", chatId: "c1", fromUserId: "me", sentAt: 42,
                              kind: .text, text: "привет", status: .sent, isOutgoing: true)
            msg.msgId = "m1"
            msg.seq = 7
            try msg.save(dbc)
        }

        var request = ContentPayload(kind: "repairRequest")
        request.targetMsgId = "m1"
        request.repairSeq = 7
        request.reason = "no_session"
        request.attempt = 1
        await engine.handleRepairContent(request, chatId: "c1", from: "peer", fromDevice: "d1")

        let outbox = try await outboxContents(db)
        XCTAssertEqual(outbox.count, 1)
        XCTAssertEqual(outbox[0].id, MessageRepair.replyId(msgId: "m1", attempt: 1))
        let reply = outbox[0].content
        XCTAssertEqual(reply.kind, "repair")
        XCTAssertEqual(reply.to, "peer")
        XCTAssertEqual(reply.repairOf, "m1")
        XCTAssertEqual(reply.repairSeq, 7)
        XCTAssertEqual(reply.origSentAt, 42)
        let original = try JSONDecoder().decode(ContentPayload.self,
                                                from: Data(try XCTUnwrap(reply.orig).utf8))
        XCTAssertEqual(original.kind, "text")
        XCTAssertEqual(original.text, "привет")
    }

    /// Чужого сообщения у нас нет — отвечать нечем, и в очередь ничего не идёт.
    func testSenderIgnoresRequestForMessageItDoesNotHold() async throws {
        let db = try AppDatabase.openInMemory()
        try await makeDirectChat(db)
        let engine = try makeEngine(db: db)

        var request = ContentPayload(kind: "repairRequest")
        request.targetMsgId = "unknown"
        request.attempt = 1
        await engine.handleRepairContent(request, chatId: "c1", from: "peer", fromDevice: "d1")

        let outbox = try await outboxContents(db)
        XCTAssertTrue(outbox.isEmpty)
    }

    // MARK: - Сторона получателя

    /// Копия встаёт под исходным msgId: в ленте одно сообщение, а не два, и
    /// повтор копии тоже дубля не делает.
    func testRepairedCopyReplacesGapWithoutDuplicate() async throws {
        let db = try AppDatabase.openInMemory()
        try await makeDirectChat(db)
        let engine = try makeEngine(db: db)

        await engine.apply(try brokenFrame(seq: 1, msgId: "m1"))

        var original = ContentPayload(kind: "text")
        original.text = "привет"
        var repair = ContentPayload(kind: "repair")
        repair.repairOf = "m1"
        repair.repairSeq = 1
        repair.origSentAt = 42
        repair.orig = SyncEngine.payloadJSON(original)

        await engine.handleRepairContent(repair, chatId: "c1", from: "peer", fromDevice: "d1")
        await engine.handleRepairContent(repair, chatId: "c1", from: "peer", fromDevice: "d1")

        let rows = try await db.read { dbc in
            try Message.fetchAll(dbc, sql: "SELECT * FROM message WHERE chatId = 'c1'")
        }
        XCTAssertEqual(rows.count, 1, "повторная копия создала дубль в ленте")
        XCTAssertEqual(rows[0].msgId, "m1")
        XCTAssertEqual(rows[0].seq, 1)
        XCTAssertEqual(rows[0].text, "привет")
        XCTAssertEqual(rows[0].sentAt, 42)

        let leftovers = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM pendingDecrypt")! +
                Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM historyGap")!
        }
        XCTAssertEqual(leftovers, 0, "после починки запись о пропаже осталась")
    }

    /// Заявка до принятия: запрос копии не уходит, иначе автор узнал бы, что на
    /// той стороне кто-то есть. Конверт при этом сохранён и дождётся принятия.
    func testRequestChatDoesNotAskUntilAccepted() async throws {
        let db = try AppDatabase.openInMemory()
        try await makeDirectChat(db)
        try await db.write { dbc in
            try dbc.execute(sql: "UPDATE chat SET isRequest = 1, iAccepted = 0 WHERE id = 'c1'")
        }
        let engine = try makeEngine(db: db)

        await engine.apply(try brokenFrame(seq: 1, msgId: "m1"))
        let queued = try await outboxContents(db)
        XCTAssertTrue(queued.isEmpty, "запрос ушёл из непринятой заявки")

        let kept = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM pendingDecrypt")!
        }
        XCTAssertEqual(kept, 1, "конверт заявки не сохранён")

        // после принятия проход просит копию
        try await db.write { dbc in
            try dbc.execute(sql: "UPDATE chat SET isRequest = 0, iAccepted = 1 WHERE id = 'c1'")
            try dbc.execute(sql: "UPDATE pendingDecrypt SET lastTriedAt = 0")
        }
        await engine.sweepUnreadable()
        let asked = try await outboxContents(db)
        XCTAssertEqual(asked.first?.content.kind, "repairRequest")
    }

    /// Копию принимаем только от автора пропавшего сообщения: иначе участник
    /// чата подменил бы чужое сообщение своим текстом.
    func testRepairFromSomeoneElseIsRejected() async throws {
        let db = try AppDatabase.openInMemory()
        try await makeDirectChat(db)
        let engine = try makeEngine(db: db)

        await engine.apply(try brokenFrame(seq: 1, msgId: "m1"))

        var forged = ContentPayload(kind: "text")
        forged.text = "подмена"
        var repair = ContentPayload(kind: "repair")
        repair.repairOf = "m1"
        repair.repairSeq = 1
        repair.orig = SyncEngine.payloadJSON(forged)
        await engine.handleRepairContent(repair, chatId: "c1", from: "stranger", fromDevice: "d9")

        let rows = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = 'c1'")!
        }
        XCTAssertEqual(rows, 0, "чужая копия попала в ленту")
    }

    /// Вступивший позже участник просит копию старого сообщения: отвечать
    /// нельзя, иначе он получит историю, закрытую для него сменой цепочки.
    func testRequestForMessageOlderThanMembershipIsRefused() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try await db.write { dbc in
            try dbc.execute(sql: "INSERT INTO chat (id, kind, createdBy, createdAt) VALUES ('g1','group','me',0)")
            try dbc.execute(sql: "INSERT INTO member (chatId, userId, role, joinedAt) VALUES ('g1','me','owner',0)")
            try dbc.execute(sql: "INSERT INTO member (chatId, userId, role, joinedAt) VALUES ('g1','late','member',100)")
            var msg = Message(id: "local1", chatId: "g1", fromUserId: "me", sentAt: 42,
                              kind: .text, text: "до его прихода", status: .sent, isOutgoing: true)
            msg.msgId = "m1"
            msg.seq = 7
            try msg.save(dbc)
        }

        var request = ContentPayload(kind: "repairRequest")
        request.targetMsgId = "m1"
        request.repairSeq = 7
        request.attempt = 1
        await engine.handleRepairContent(request, chatId: "g1", from: "late", fromDevice: "d1")

        let outbox = try await outboxContents(db)
        XCTAssertTrue(outbox.isEmpty, "старое сообщение уехало вступившему позже")
    }

    /// Подтверждение раздачи sender key закрывает адрес: следующее сообщение в
    /// группу цепочку ему не перераздаёт.
    func testSenderKeyConfirmationClosesDistribution() async throws {
        let db = try AppDatabase.openInMemory()
        let api = APIClient(baseURL: URL(string: "http://localhost:1")!)
        let store = try IdentityStore(db: db, masterKeyProvider: StaticMasterKey())
        let e2ee = E2EEManager(store: store, api: api, ownUserId: "me", ownDeviceId: "dev")
        let state = SenderKeyState()
        try store.saveSenderKeyOut(chatId: "g1", state: state, distributedTo: [],
                                   attemptedAt: ["peer/d1": Date().timeIntervalSince1970])

        try e2ee.confirmSenderKey(chatId: "g1", keyId: state.keyId, userId: "peer", deviceId: "d1")
        var loaded = try XCTUnwrap(store.loadSenderKeyOut(chatId: "g1"))
        XCTAssertTrue(loaded.1.contains("peer/d1"))
        XCTAssertNil(loaded.2["peer/d1"])

        // получатель пожаловался — раздача забывается и уйдёт заново
        try e2ee.forgetSenderKeyDistribution(chatId: "g1", userId: "peer")
        loaded = try XCTUnwrap(store.loadSenderKeyOut(chatId: "g1"))
        XCTAssertFalse(loaded.1.contains("peer/d1"))
    }

    // MARK: - Расписание

    func testScheduleTerminalAsksAtOnceAndBacksOff() {
        let now = 1_000_000.0
        XCTAssertTrue(MessageRepair.repairDue(reason: "unknown_mode", firstSeenAt: now,
                                              repairAttempts: 0, repairAskedAt: 0, now: now))
        // ключ ещё может доехать — ждём срок
        XCTAssertFalse(MessageRepair.repairDue(reason: "no_sender_key", firstSeenAt: now,
                                               repairAttempts: 0, repairAskedAt: 0, now: now))
        XCTAssertTrue(MessageRepair.repairDue(reason: "no_sender_key",
                                              firstSeenAt: now - MessageRepair.repairGrace,
                                              repairAttempts: 0, repairAskedAt: 0, now: now))
        // после запроса пауза выдерживается и растёт
        XCTAssertFalse(MessageRepair.repairDue(reason: "unknown_mode", firstSeenAt: now,
                                               repairAttempts: 1, repairAskedAt: now - 5, now: now))
        XCTAssertTrue(MessageRepair.repairDue(reason: "unknown_mode", firstSeenAt: now,
                                              repairAttempts: 1, repairAskedAt: now - 60, now: now))
        XCTAssertFalse(MessageRepair.repairDue(reason: "unknown_mode", firstSeenAt: now,
                                               repairAttempts: 2, repairAskedAt: now - 60, now: now))
        // попытки исчерпаны
        XCTAssertFalse(MessageRepair.repairDue(reason: "unknown_mode", firstSeenAt: now,
                                               repairAttempts: MessageRepair.maxAttempts,
                                               repairAskedAt: 0, now: now))
    }
}
