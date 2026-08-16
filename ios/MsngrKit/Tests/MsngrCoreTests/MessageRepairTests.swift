import XCTest
import GRDB
import MsngrCrypto
@testable import MsngrCore

/// Repair of unreadable messages: the envelope is kept whatever the failure,
/// the queue replays itself, and what cannot be replayed is requested from the
/// sender. No server needed: the engine is built against an address nothing
/// listens on, so sends pile up in the outbox.
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

    /// An envelope this session will never open: the mode is unknown.
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

    // MARK: - Keeping the envelope and asking for a copy

    /// A terminal failure: the envelope stays in the database so there is
    /// something to retry locally, the seq is recorded as missing, and a request
    /// for a copy goes to the sender.
    func testTerminalFailureKeepsEnvelopeAndAsksSender() async throws {
        let db = try AppDatabase.openInMemory()
        try await makeDirectChat(db)
        let engine = try makeEngine(db: db)

        await engine.apply(try brokenFrame(seq: 1, msgId: "m1"))

        let pending = try await db.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT * FROM pendingDecrypt WHERE chatId = 'c1' AND msgId = 'm1'")
        }
        let row = try XCTUnwrap(pending, "the envelope was not kept, nothing left to retry")
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

    /// A missing key is not a defect by itself: the envelope is parked and the
    /// sender is left alone until the grace period runs out.
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
        XCTAssertTrue(outbox.isEmpty, "asked for a copy before the key grace period was over")
    }

    /// The parked queue is replayed when the engine starts, not only after a
    /// successful frame in the same chat, otherwise a row waits forever.
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
        XCTAssertGreaterThan(attempts, 1, "the queue was not replayed on start")

        var outbox = try await outboxContents(db)
        for _ in 0..<50 where outbox.isEmpty {
            try await Task.sleep(nanoseconds: 40_000_000)
            outbox = try await outboxContents(db)
        }
        XCTAssertEqual(outbox.first?.content.kind, "repairRequest")
    }

    /// The attempt counter grows and caps the repeats: once it is spent the
    /// engine stops asking for a copy, however many sweeps run.
    func testAttemptsGrowAndCapRepeats() async throws {
        let db = try AppDatabase.openInMemory()
        try await makeDirectChat(db)
        let engine = try makeEngine(db: db)

        await engine.apply(try brokenFrame(seq: 1, msgId: "m1"))
        // every sweep finds the backoff elapsed and the envelope not yet expired
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
                       "more requests than the allowed number of attempts")

        // once the attempts are spent the seq becomes a placeholder in the feed
        let shown = try await db.read { dbc in
            try HistoryWindow.exhaustedGapSeqs(dbc, chatId: "c1", floor: nil)
        }
        XCTAssertEqual(shown, [1])
    }

    /// An envelope with its attempts spent and its lifetime over is forgotten,
    /// but the record of the missing seq stays, so pagination will not go back
    /// to the server for it.
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

    // MARK: - Sender side

    /// A request for a copy where the sender still has the message locally: it
    /// goes back to the asker under the original msgId.
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

    /// We do not hold someone else's message, so there is nothing to answer with
    /// and nothing is queued.
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

    // MARK: - Recipient side

    /// The copy lands under the original msgId, so the feed shows one message;
    /// a second copy does not create a duplicate either.
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
        XCTAssertEqual(rows.count, 1, "the repeated copy created a duplicate in the feed")
        XCTAssertEqual(rows[0].msgId, "m1")
        XCTAssertEqual(rows[0].seq, 1)
        XCTAssertEqual(rows[0].text, "привет")
        XCTAssertEqual(rows[0].sentAt, 42)

        let leftovers = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM pendingDecrypt")! +
                Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM historyGap")!
        }
        XCTAssertEqual(leftovers, 0, "the record of the gap survived the repair")
    }

    /// A request before it is accepted: no copy is asked for, otherwise the
    /// author would learn someone is on the other side. The envelope is still
    /// kept and waits for the acceptance.
    func testRequestChatDoesNotAskUntilAccepted() async throws {
        let db = try AppDatabase.openInMemory()
        try await makeDirectChat(db)
        try await db.write { dbc in
            try dbc.execute(sql: "UPDATE chat SET isRequest = 1, iAccepted = 0 WHERE id = 'c1'")
        }
        let engine = try makeEngine(db: db)

        await engine.apply(try brokenFrame(seq: 1, msgId: "m1"))
        let queued = try await outboxContents(db)
        XCTAssertTrue(queued.isEmpty, "a request went out from a chat request that was never accepted")

        let kept = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM pendingDecrypt")!
        }
        XCTAssertEqual(kept, 1, "the envelope of a chat request was not kept")

        // once accepted, the sweep does ask for a copy
        try await db.write { dbc in
            try dbc.execute(sql: "UPDATE chat SET isRequest = 0, iAccepted = 1 WHERE id = 'c1'")
            try dbc.execute(sql: "UPDATE pendingDecrypt SET lastTriedAt = 0")
        }
        await engine.sweepUnreadable()
        let asked = try await outboxContents(db)
        XCTAssertEqual(asked.first?.content.kind, "repairRequest")
    }

    /// A copy is accepted only from the author of the missing message, otherwise
    /// any chat member could replace someone else's message with their own text.
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
        XCTAssertEqual(rows, 0, "a copy from a third party reached the feed")
    }

    /// A member who joined later asks for a copy of an older message: answering
    /// would hand them history the chain rotation closed off from them.
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
        XCTAssertTrue(outbox.isEmpty, "an old message went out to a member who joined later")
    }

    /// Confirming a sender key delivery closes that address: the next message to
    /// the group does not redistribute the chain to it.
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

        // the recipient complained: the delivery is forgotten and will go out again
        try e2ee.forgetSenderKeyDistribution(chatId: "g1", userId: "peer")
        loaded = try XCTUnwrap(store.loadSenderKeyOut(chatId: "g1"))
        XCTAssertFalse(loaded.1.contains("peer/d1"))
    }

    // MARK: - Schedule

    func testScheduleTerminalAsksAtOnceAndBacksOff() {
        let now = 1_000_000.0
        XCTAssertTrue(MessageRepair.repairDue(reason: "unknown_mode", firstSeenAt: now,
                                              repairAttempts: 0, repairAskedAt: 0, now: now))
        // the key may still arrive, so wait out the grace period
        XCTAssertFalse(MessageRepair.repairDue(reason: "no_sender_key", firstSeenAt: now,
                                               repairAttempts: 0, repairAskedAt: 0, now: now))
        XCTAssertTrue(MessageRepair.repairDue(reason: "no_sender_key",
                                              firstSeenAt: now - MessageRepair.repairGrace,
                                              repairAttempts: 0, repairAskedAt: 0, now: now))
        // after a request the backoff is honoured and grows
        XCTAssertFalse(MessageRepair.repairDue(reason: "unknown_mode", firstSeenAt: now,
                                               repairAttempts: 1, repairAskedAt: now - 5, now: now))
        XCTAssertTrue(MessageRepair.repairDue(reason: "unknown_mode", firstSeenAt: now,
                                              repairAttempts: 1, repairAskedAt: now - 60, now: now))
        XCTAssertFalse(MessageRepair.repairDue(reason: "unknown_mode", firstSeenAt: now,
                                               repairAttempts: 2, repairAskedAt: now - 60, now: now))
        // attempts are spent
        XCTAssertFalse(MessageRepair.repairDue(reason: "unknown_mode", firstSeenAt: now,
                                               repairAttempts: MessageRepair.maxAttempts,
                                               repairAskedAt: 0, now: now))
    }
}
