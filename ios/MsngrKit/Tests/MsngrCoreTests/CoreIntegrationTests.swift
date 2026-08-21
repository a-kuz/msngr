import XCTest
import GRDB
import MsngrCrypto
@testable import MsngrCore

/// End-to-end test of the core against a local server (wrangler dev on :8787).
/// Skipped when nothing is listening there.
final class CoreIntegrationTests: XCTestCase {
    /// Dev server address; override with the MSNGR_TEST_BASE environment variable.
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
            throw XCTSkip("wrangler dev is not running")
        }
        let suffix = String(UUID().uuidString.prefix(6)).lowercased().replacingOccurrences(of: "-", with: "x")
        let alice = try await Self.makeClient(username: "ca_\(suffix)")
        let bob = try await Self.makeClient(username: "cb_\(suffix)")

        // Alice creates a direct chat and sends an encrypted message
        let chatId = try await alice.api.createChat(kind: "direct", memberIds: [bob.userId], title: nil)
        try await alice.engine.refreshSnapshot()
        var content = ContentPayload(kind: "text")
        content.text = "hello, this is e2e"
        try await alice.engine.enqueue(content: content, chatId: chatId)

        // on Alice's side the message gets a seq and the sent status
        let acked = try await waitUntil {
            try await alice.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND seq IS NOT NULL AND status >= 1",
                                 arguments: [chatId]) == 1
            }
        }
        XCTAssertTrue(acked, "no ack arrived")

        // Bob receives the chat and decrypts the message
        let received = try await waitUntil {
            try await bob.db.read { dbc in
                (try String.fetchOne(dbc, sql: "SELECT text FROM message WHERE chatId = ?",
                                     arguments: [chatId])) == "hello, this is e2e"
            }
        }
        XCTAssertTrue(received, "Bob did not decrypt the message")

        // for Bob the chat is marked as a message request
        let isRequest = try await bob.db.read { dbc in
            try Bool.fetchOne(dbc, sql: "SELECT isRequest FROM chat WHERE id = ?", arguments: [chatId]) ?? false
        }
        XCTAssertTrue(isRequest, "the chat must be a request until it is accepted")

        // Bob replies after accepting, which ratchets in the other direction
        try await bob.api.acceptChat(chatId)
        var reply = ContentPayload(kind: "text")
        reply.text = "reply from bob"
        try await bob.engine.enqueue(content: reply, chatId: chatId)

        let gotReply = try await waitUntil {
            try await alice.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND text = 'reply from bob'",
                                 arguments: [chatId]) == 1
            }
        }
        XCTAssertTrue(gotReply, "Alice did not get the reply")

        // read receipt: Bob reads, and Alice's message turns to read
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
        XCTAssertTrue(readMark, "the read receipt never arrived")

        await alice.engine.stop()
        await bob.engine.stop()
    }

    /// A recipient whose identity bundle carries no signature (an account
    /// registered before the identity binding and never healed) must not take
    /// the sender down with it: the message to them waits in the outbox with
    /// the clock, and a message to a healthy recipient sends past it instead
    /// of queueing behind it forever.
    func testUnsignedRecipientDoesNotBlockTheOutbox() async throws {
        guard await Self.serverUp() else { throw XCTSkip("wrangler dev is not running") }
        let suffix = String(UUID().uuidString.prefix(6)).lowercased().replacingOccurrences(of: "-", with: "x")
        let alice = try await Self.makeClient(username: "ua_\(suffix)")
        let carol = try await Self.makeClient(username: "uc_\(suffix)")

        // Bob is registered the way the pre-binding accounts read to a sender:
        // real keys, an identity signature that does not verify.
        let bobDb = try AppDatabase.openInMemory()
        let bobStore = try IdentityStore(db: bobDb, masterKeyProvider: StaticMasterKey())
        let bobIdentity = try bobStore.identity()
        let bobPrekeys = try bobStore.generatePrekeys(count: 5)
        let bobApi = APIClient(baseURL: Self.base)
        let bobReg = try await bobApi.register(.init(
            username: "ub_\(suffix)", displayName: "ub", deviceName: "test",
            identityKey: bobIdentity.dh.publicKey.rawRepresentation.base64urlEncodedString(),
            identitySignKey: bobIdentity.signing.publicKey.rawRepresentation.base64urlEncodedString(),
            identityKeySig: Data(repeating: 0, count: 64).base64urlEncodedString(),
            signedPrekey: .init(id: bobPrekeys.signedPrekey.id,
                                key: bobPrekeys.signedPrekey.key.publicKey.rawRepresentation.base64urlEncodedString(),
                                sig: bobPrekeys.signedPrekey.signature.base64urlEncodedString()),
            oneTimePrekeys: bobPrekeys.oneTime.map {
                .init(id: $0.id, key: $0.key.publicKey.rawRepresentation.base64urlEncodedString())
            },
            phoneHash: nil))

        let bobChat = try await alice.api.createChat(kind: "direct", memberIds: [bobReg.userId], title: nil)
        let carolChat = try await alice.api.createChat(kind: "direct", memberIds: [carol.userId], title: nil)
        try await alice.engine.refreshSnapshot()

        var toBob = ContentPayload(kind: "text")
        toBob.text = "to the unsigned account"
        try await alice.engine.enqueue(content: toBob, chatId: bobChat)
        var toCarol = ContentPayload(kind: "text")
        toCarol.text = "to the healthy account"
        try await alice.engine.enqueue(content: toCarol, chatId: carolChat)

        // the healthy send goes through even while the unsigned one waits
        let carolGotIt = try await waitUntil {
            try await carol.db.read { dbc in
                (try String.fetchOne(dbc, sql: "SELECT text FROM message WHERE chatId = ?",
                                     arguments: [carolChat])) == "to the healthy account"
            }
        }
        XCTAssertTrue(carolGotIt, "the healthy recipient must not queue behind the unsigned one")

        // the message to Bob keeps the clock: still in the outbox, not failed
        let bobStatus = try await alice.db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT status FROM message WHERE chatId = ?", arguments: [bobChat])
        }
        XCTAssertEqual(bobStatus, 0, "the unsigned send must wait, not fail")
        let outboxState = try await alice.db.read { dbc in
            try String.fetchOne(dbc, sql: "SELECT state FROM outbox WHERE chatId = ?", arguments: [bobChat])
        }
        XCTAssertEqual(outboxState, "ready", "the message must stay in the outbox for a retry")

        await alice.engine.stop()
        await carol.engine.stop()
    }

    /// The recipient's app is not running: no socket, and the message arrives
    /// as the notification extension takes it — written from the push and
    /// answered over HTTP. This is the extension's path through the core, with
    /// APNs replaced by the payload it would have carried.
    func testDeliveredReceiptWithoutASocket() async throws {
        guard await Self.serverUp() else { throw XCTSkip("wrangler dev is not running") }
        let suffix = String(UUID().uuidString.prefix(6)).lowercased().replacingOccurrences(of: "-", with: "x")
        let alice = try await Self.makeClient(username: "ra_\(suffix)")
        let bob = try await Self.makeClient(username: "rb_\(suffix)")

        let chatId = try await alice.api.createChat(kind: "direct", memberIds: [bob.userId], title: nil)
        try await alice.engine.refreshSnapshot()
        try await bob.api.acceptChat(chatId)
        try await bob.engine.refreshSnapshot()

        // from here Bob's app is gone: the socket is closed and the extension is
        // the only thing that sees the message
        await bob.engine.stop()

        var content = ContentPayload(kind: "text")
        content.text = "while the app was dead"
        try await alice.engine.enqueue(content: content, chatId: chatId)
        let sent = try await waitUntil {
            try await alice.db.read { dbc in
                try Int.fetchOne(dbc, sql: """
                    SELECT COUNT(*) FROM message WHERE chatId = ? AND seq IS NOT NULL
                    """, arguments: [chatId]) == 1
            }
        }
        XCTAssertTrue(sent, "no ack arrived")
        let addressed = try await alice.db.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT seq FROM message WHERE chatId = ?",
                             arguments: [chatId])
        }
        let seq: Int = addressed!["seq"]

        // the extension's transaction: the message of the push goes in, the
        // receipt it owes goes into the queue with it
        _ = try NotificationBurstStore.resolve(
            db: bob.db, items: [BurstItem(chatId: chatId, seq: seq, sentAt: 0)],
            showsMessageText: true)
        let queued = try await bob.db.read { dbc in try DeliveryReceipts.pending(dbc) }
        XCTAssertEqual(queued.first?.upToSeq, seq, "the receipt was not written down")

        await DeliveryReceipts.flush(db: bob.db, api: bob.api)

        let delivered = try await waitUntil {
            try await alice.db.read { dbc in
                try Int.fetchOne(dbc, sql: """
                    SELECT status FROM message WHERE chatId = ? AND isOutgoing = 1
                    """, arguments: [chatId]) == MessageStatus.delivered.rawValue
            }
        }
        XCTAssertTrue(delivered, "the author is still on one tick")
        let empty = try await bob.db.read { dbc in try DeliveryReceipts.pending(dbc) }
        XCTAssertTrue(empty.isEmpty, "a receipt the server took must leave the queue")

        await alice.engine.stop()
    }

    /// Both sides write first, initiating the session at the same time. Neither
    /// side may lose a message.
    func testSimultaneousFirstMessagesBothDecrypt() async throws {
        guard await Self.serverUp() else { throw XCTSkip("wrangler dev is not running") }
        let suffix = String(UUID().uuidString.prefix(6)).lowercased().replacingOccurrences(of: "-", with: "x")
        let a = try await Self.makeClient(username: "ga_\(suffix)")
        let b = try await Self.makeClient(username: "gb_\(suffix)")

        // A creates the chat and writes; B writes into the same chat independently
        let chatId = try await a.api.createChat(kind: "direct", memberIds: [b.userId], title: nil)
        try await a.engine.refreshSnapshot()
        try await b.engine.refreshSnapshot()

        var m1 = ContentPayload(kind: "text"); m1.text = "from A"
        var m2 = ContentPayload(kind: "text"); m2.text = "from B"
        async let s1: Void = a.engine.enqueue(content: m1, chatId: chatId)
        async let s2: Void = b.engine.enqueue(content: m2, chatId: chatId)
        _ = try await (s1, s2)

        let bGotA = try await waitUntil(12) {
            try await b.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND text = 'from A'",
                                 arguments: [chatId]) == 1
            }
        }
        let aGotB = try await waitUntil(12) {
            try await a.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND text = 'from B'",
                                 arguments: [chatId]) == 1
            }
        }
        XCTAssertTrue(bGotA, "B did not decrypt A's message")
        XCTAssertTrue(aGotB, "A did not decrypt B's message")

        // and the conversation keeps flowing both ways
        var m3 = ContentPayload(kind: "text"); m3.text = "reply from A"
        try await a.engine.enqueue(content: m3, chatId: chatId)
        let bGotReply = try await waitUntil(12) {
            try await b.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND text = 'reply from A'",
                                 arguments: [chatId]) == 1
            }
        }
        XCTAssertTrue(bGotReply, "the conversation fell apart after the crossing initiation")

        // nothing unreadable on either side: no parked envelope and no record of
        // a missing seq
        for (name, c) in [("A", a), ("B", b)] {
            let bad = try await c.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM pendingDecrypt")! +
                    Int.fetchOne(dbc, sql: """
                        SELECT COUNT(*) FROM historyGap WHERE reason NOT IN ('service','sender_key')
                        """)!
            }
            XCTAssertEqual(bad, 0, "\(name) has unreadable messages")
        }

        await a.engine.stop()
        await b.engine.stop()
    }

    func testGroupChatSenderKeys() async throws {
        guard await Self.serverUp() else {
            throw XCTSkip("wrangler dev is not running")
        }
        let suffix = String(UUID().uuidString.prefix(6)).lowercased().replacingOccurrences(of: "-", with: "x")
        let alice = try await Self.makeClient(username: "ga_\(suffix)")
        let bob = try await Self.makeClient(username: "gb_\(suffix)")
        let carol = try await Self.makeClient(username: "gc_\(suffix)")

        let chatId = try await alice.api.createChat(kind: "group",
                                                    memberIds: [bob.userId, carol.userId],
                                                    title: "Group")
        try await alice.engine.refreshSnapshot()

        var content = ContentPayload(kind: "text")
        content.text = "group message"
        try await alice.engine.enqueue(content: content, chatId: chatId)

        // both members decrypt through the sender key
        for (name, client) in [("bob", bob), ("carol", carol)] {
            let ok = try await waitUntil {
                try await client.db.read { dbc in
                    (try String.fetchOne(dbc, sql: "SELECT text FROM message WHERE chatId = ? AND kind = 'text'",
                                         arguments: [chatId])) == "group message"
                }
            }
            XCTAssertTrue(ok, "\(name) did not decrypt the group message")
        }

        // Bob replies: his sender key is distributed, Alice and Carol can read it
        var reply = ContentPayload(kind: "text")
        reply.text = "reply in the group"
        try await bob.engine.enqueue(content: reply, chatId: chatId)
        for (name, client) in [("alice", alice), ("carol", carol)] {
            let ok = try await waitUntil {
                try await client.db.read { dbc in
                    try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND text = 'reply in the group'",
                                     arguments: [chatId]) == 1
                }
            }
            XCTAssertTrue(ok, "\(name) did not get the group reply")
        }

        // reaction: Carol puts a heart on Alice's message
        let targetLocalId = try await carol.db.read { dbc in
            try String.fetchOne(dbc, sql: "SELECT id FROM message WHERE chatId = ? AND text = 'group message'",
                                arguments: [chatId])
        }
        let targetSeq = try await carol.db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT seq FROM message WHERE chatId = ? AND text = 'group message'",
                             arguments: [chatId])
        }
        var reaction = ContentPayload(kind: "reaction")
        reaction.targetLocalId = targetLocalId
        reaction.emoji = "❤️"
        try await carol.engine.enqueue(content: reaction, chatId: chatId)
        let reacted = try await waitUntil {
            try await alice.db.read { dbc in
                let r = try String.fetchOne(dbc, sql: "SELECT reactions FROM message WHERE chatId = ? AND seq = ?",
                                            arguments: [chatId, targetSeq]) ?? "{}"
                return r.contains("❤️")
            }
        }
        XCTAssertTrue(reacted, "the reaction never reached Alice")

        // forward secrecy: Carol is removed, Alice rotates the sender key and
        // sends again. Bob can read it, Carol cannot.
        try await alice.api.updateMembers(chatId, add: [], remove: [carol.userId])
        _ = try await waitUntil {
            try await alice.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM member WHERE chatId = ? AND userId = ?",
                                 arguments: [chatId, carol.userId]) == 0
            }
        }
        var after = ContentPayload(kind: "text")
        after.text = "after removing carol"
        try await alice.engine.enqueue(content: after, chatId: chatId)
        let bobGot = try await waitUntil {
            try await bob.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND text = 'after removing carol'",
                                 arguments: [chatId]) == 1
            }
        }
        XCTAssertTrue(bobGot, "Bob must receive the message sent after the rotation")
        // leave time for a delivery to Carol that must not happen
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let carolLeaked = try await carol.db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND text = 'after removing carol'",
                             arguments: [chatId]) ?? 0
        }
        XCTAssertEqual(carolLeaked, 0, "a removed member must not read new messages")

        await alice.engine.stop()
        await bob.engine.stop()
        await carol.engine.stop()
    }

    func testOfflineOutboxAndResync() async throws {
        guard await Self.serverUp() else {
            throw XCTSkip("wrangler dev is not running")
        }
        let suffix = String(UUID().uuidString.prefix(6)).lowercased().replacingOccurrences(of: "-", with: "x")
        let alice = try await Self.makeClient(username: "oa_\(suffix)")
        let bob = try await Self.makeClient(username: "ob_\(suffix)")

        let chatId = try await alice.api.createChat(kind: "direct", memberIds: [bob.userId], title: nil)
        try await alice.engine.refreshSnapshot()

        // Bob goes offline
        await bob.engine.stop()

        var m1 = ContentPayload(kind: "text"); m1.text = "while you were offline 1"
        var m2 = ContentPayload(kind: "text"); m2.text = "while you were offline 2"
        try await alice.engine.enqueue(content: m1, chatId: chatId)
        try await alice.engine.enqueue(content: m2, chatId: chatId)
        _ = try await waitUntil {
            try await alice.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND seq IS NOT NULL",
                                 arguments: [chatId]) == 2
            }
        }

        // Bob comes back: the cursor sync delivers what he missed
        await bob.engine.start()
        let caught = try await waitUntil(10) {
            try await bob.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND kind = 'text'",
                                 arguments: [chatId]) == 2
            }
        }
        XCTAssertTrue(caught, "the offline messages did not arrive after the reconnect")

        await alice.engine.stop()
        await bob.engine.stop()
    }

    /// The recipient's session state is corrupted, so no envelope from the sender
    /// opens any more. The device repairs itself: it asks for a copy, rebuilds
    /// the session and puts the message into the feed under the original seq,
    /// without a duplicate.
    func testCorruptedSessionIsRepairedThroughSender() async throws {
        guard await Self.serverUp() else {
            throw XCTSkip("wrangler dev is not running")
        }
        let suffix = String(UUID().uuidString.prefix(6)).lowercased().replacingOccurrences(of: "-", with: "x")
        let alice = try await Self.makeClient(username: "ra_\(suffix)")
        let bob = try await Self.makeClient(username: "rb_\(suffix)")

        let chatId = try await alice.api.createChat(kind: "direct", memberIds: [bob.userId], title: nil)
        try await alice.engine.refreshSnapshot()
        var first = ContentPayload(kind: "text")
        first.text = "before the break"
        try await alice.engine.enqueue(content: first, chatId: chatId)
        let gotFirst = try await waitUntil {
            try await bob.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND text = 'before the break'",
                                 arguments: [chatId]) == 1
            }
        }
        XCTAssertTrue(gotFirst, "the first message never arrived")
        // while the chat is an unaccepted request the repair stays quiet: it would
        // tell the author that the recipient is there. After the accept it is an
        // ordinary chat
        try await bob.api.acceptChat(chatId)
        try await bob.engine.refreshSnapshot()

        // Bob's session state is overwritten with garbage: nothing left to decrypt with
        try await bob.db.write { dbc in
            try dbc.execute(sql: "UPDATE ratchetSession SET state = ?, archived = NULL",
                            arguments: [Data(repeating: 0x7f, count: 48)])
        }

        var lost = ContentPayload(kind: "text")
        lost.text = "after the break"
        try await alice.engine.enqueue(content: lost, chatId: chatId)
        let recorded = try await waitUntil {
            try await bob.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM pendingDecrypt WHERE chatId = ?",
                                 arguments: [chatId]) == 1
            }
        }
        XCTAssertTrue(recorded, "the unreadable envelope was not kept")
        let keptEnvelope = try await bob.db.read { dbc in
            (try Row.fetchOne(dbc, sql: "SELECT body FROM pendingDecrypt")?["body"] as Data?) ?? Data()
        }
        XCTAssertFalse(keptEnvelope.isEmpty, "the envelope was kept empty, nothing left to retry")

        // the key grace period has passed, so the sweep asks the sender for a copy
        try await bob.db.write { dbc in
            try dbc.execute(sql: "UPDATE pendingDecrypt SET firstSeenAt = ?, lastTriedAt = 0",
                            arguments: [Date().timeIntervalSince1970 - MessageRepair.repairGrace - 1])
        }
        await bob.engine.sweepUnreadable()

        let repaired = try await waitUntil(15) {
            try await bob.db.read { dbc in
                try String.fetchOne(dbc, sql: "SELECT text FROM message WHERE chatId = ? AND text = 'after the break'",
                                    arguments: [chatId]) != nil
            }
        }
        XCTAssertTrue(repaired, "the message was never repaired")

        // exactly one row per message and no record of a gap
        let rows = try await bob.db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND text = 'after the break'",
                             arguments: [chatId])!
        }
        XCTAssertEqual(rows, 1, "the repaired message was duplicated")
        let leftovers = try await bob.db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM pendingDecrypt")! +
                Int.fetchOne(dbc, sql: """
                    SELECT COUNT(*) FROM historyGap WHERE reason NOT IN ('service','sender_key')
                    """)!
        }
        XCTAssertEqual(leftovers, 0, "traces of the gap survived the repair")

        // the session is rebuilt: the next message reads without any repair
        var after = ContentPayload(kind: "text")
        after.text = "after the repair"
        try await alice.engine.enqueue(content: after, chatId: chatId)
        let flows = try await waitUntil(10) {
            try await bob.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND text = 'after the repair'",
                                 arguments: [chatId]) == 1
            }
        }
        XCTAssertTrue(flows, "the conversation did not resume after the repair")

        await alice.engine.stop()
        await bob.engine.stop()
    }

    /// The device is back after a long time offline: same database, same keys, a
    /// new socket. Catch-up resumes from the cursors stored in the database.
    static func restarted(_ c: TestClient) async -> SyncEngine {
        var comps = URLComponents(url: base.appendingPathComponent("ws"), resolvingAgainstBaseURL: false)!
        comps.scheme = "ws"
        comps.queryItems = [URLQueryItem(name: "token", value: c.api.token)]
        let engine = SyncEngine(db: c.db, api: c.api, e2ee: c.e2ee, wsURL: comps.url!,
                                ownUserId: c.userId, ownDeviceId: c.deviceId)
        await engine.start()
        return engine
    }

    /// A long time offline: what piled up arrives in batches, every message
    /// exactly once, and the cursor reaches the end of the log.
    func testLongOfflineCatchesUpInPortions() async throws {
        guard await Self.serverUp() else { throw XCTSkip("wrangler dev is not running") }
        let suffix = String(UUID().uuidString.prefix(6)).lowercased().replacingOccurrences(of: "-", with: "x")
        let alice = try await Self.makeClient(username: "pa_\(suffix)")
        let bob = try await Self.makeClient(username: "pb_\(suffix)")

        let chatId = try await alice.api.createChat(kind: "direct", memberIds: [bob.userId], title: nil)
        try await alice.engine.refreshSnapshot()
        var hello = ContentPayload(kind: "text")
        hello.text = "greetings"
        try await alice.engine.enqueue(content: hello, chatId: chatId)
        let opened = try await waitUntil(12) {
            try await bob.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND text = 'greetings'",
                                 arguments: [chatId]) == 1
            }
        }
        XCTAssertTrue(opened, "the first message never arrived")
        try await bob.api.acceptChat(chatId)

        // Bob is offline while Alice sends 300 messages
        await bob.engine.stop()
        let total = 300
        for i in 1...total {
            var m = ContentPayload(kind: "text")
            m.text = "offline \(i)"
            try await alice.engine.enqueue(content: m, chatId: chatId)
        }
        let allAcked = try await waitUntil(180) {
            try await alice.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND seq IS NOT NULL",
                                 arguments: [chatId]) == total + 1
            }
        }
        XCTAssertTrue(allAcked, "not every message got a seq")

        // Bob comes back: catch-up runs batch after batch until it is done
        let engine = await Self.restarted(bob)
        let caughtUp = try await waitUntil(180) {
            try await bob.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ?",
                                 arguments: [chatId]) == total + 1
            }
        }
        XCTAssertTrue(caughtUp, "catch-up did not deliver the whole history")

        let state = try await bob.db.read { dbc -> (Int, Int, Int, Int, Int, Int) in
            let distinct = try Int.fetchOne(dbc, sql: """
                SELECT COUNT(DISTINCT seq) FROM message WHERE chatId = ? AND seq IS NOT NULL
                """, arguments: [chatId])!
            let minSeq = try Int.fetchOne(dbc, sql: "SELECT MIN(seq) FROM message WHERE chatId = ?",
                                          arguments: [chatId])!
            let maxSeq = try Int.fetchOne(dbc, sql: "SELECT MAX(seq) FROM message WHERE chatId = ?",
                                          arguments: [chatId])!
            let synced = try Int.fetchOne(dbc, sql: "SELECT syncedSeq FROM chat WHERE id = ?",
                                          arguments: [chatId])!
            let cursor = try Int.fetchOne(dbc, sql: "SELECT syncCursor FROM chat WHERE id = ?",
                                          arguments: [chatId])!
            let unreadable = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM pendingDecrypt")!
                + Int.fetchOne(dbc, sql: """
                    SELECT COUNT(*) FROM historyGap WHERE reason NOT IN ('service','sender_key')
                    """, arguments: [])!
            return (distinct, minSeq, maxSeq, synced, cursor, unreadable)
        }
        // no duplicates and no holes: the seqs run back to back from first to last
        XCTAssertEqual(state.0, total + 1, "ordering or deduplication is broken")
        XCTAssertEqual(state.1, 1)
        XCTAssertEqual(state.2, total + 1)
        XCTAssertEqual(state.3, total + 1, "the continuous prefix did not reach the end")
        XCTAssertEqual(state.4, total + 1, "the catch-up cursor did not reach the end of the log")
        XCTAssertEqual(state.5, 0, "unreadable messages were left after the catch-up")

        await alice.engine.stop()
        await engine.stop()
    }
}
