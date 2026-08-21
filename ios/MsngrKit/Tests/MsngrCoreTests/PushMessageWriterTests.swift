import XCTest
import GRDB
@testable import MsngrCore

/// A notification is a write to the database, not a picture of one: the push
/// carries the message, the extension opens it and stores it, and the chat holds
/// it afterwards with no network of any kind.
final class PushMessageWriterTests: XCTestCase {
    private struct Device {
        let location: StorageLocation
        let db: DatabaseQueue
        let store: IdentityStore
        let gate: CryptoGate
        let decryptor: IncomingDecryptor
    }

    private func makeDevice() throws -> Device {
        let location = try TestStorage.temporary()
        let db = try AppDatabase.open(at: location.databaseURL)
        let store = try IdentityStore(db: db, masterKeyProvider: SharedFileMasterKey(location: location))
        let gate = CryptoGate(url: location.cryptoGateURL)
        return Device(location: location, db: db, store: store, gate: gate,
                      decryptor: IncomingDecryptor(store: store, ownUserId: "me",
                                                   ownDeviceId: "dev", gate: gate))
    }

    private func seedChat(_ db: DatabaseQueue, id: String = "c1") throws {
        var chat = Chat(id: id, kind: .direct, title: nil, createdBy: "peer", createdAt: 0,
                        lastSeq: 0, syncedSeq: 0, lastActivityAt: 0)
        chat.myReadUpTo = 0
        try db.write { dbc in
            try chat.save(dbc)
            try User(id: "peer", username: "peer", displayName: "Peer").save(dbc)
        }
    }

    private func item(_ seq: Int) -> BurstItem {
        BurstItem(chatId: "c1", seq: seq, sentAt: Double(seq))
    }

    /// The whole point: a message that arrived only as a push is in the chat,
    /// with its text, and the banner says the same thing.
    func testPushedMessageIsStoredAndShown() throws {
        let device = try makeDevice()
        defer { TestStorage.remove(device.location) }
        try seedChat(device.db)
        var peer = try RatchetPair(store: device.store)
        let envelope = PushEnvelope(body: try peer.envelope(text: "see you at six"),
                                    fromUserId: "peer", fromDeviceId: "peerdev", ts: 100)

        let plan = try resolve(device, items: [item(1)], envelopes: ["c1/1": envelope])

        XCTAssertEqual(plan.steps.first?.outcome, .show)
        XCTAssertEqual(plan.steps.first?.content?.body, "see you at six")
        let row = try device.db.read { dbc in
            try Message.fetchOne(dbc, sql: "SELECT * FROM message WHERE chatId = 'c1' AND seq = 1")
        }
        XCTAssertEqual(row?.text, "see you at six")
        XCTAssertEqual(row?.seq, 1)
        XCTAssertEqual(row?.isOutgoing, false)
        let chat = try device.db.read { dbc in try Chat.fetchOne(dbc, key: "c1") }
        XCTAssertEqual(chat?.lastSeq, 1)
        XCTAssertEqual(chat?.syncedSeq, 1)
        XCTAssertEqual(chat?.unreadCount, 1)
    }

    /// The same message over the socket and by push lands once: the row is
    /// keyed by (chatId, seq), and the second arrival finds it there.
    func testMessageAlreadyStoredIsNotWrittenTwice() throws {
        let device = try makeDevice()
        defer { TestStorage.remove(device.location) }
        try seedChat(device.db)
        var peer = try RatchetPair(store: device.store)
        let envelope = PushEnvelope(body: try peer.envelope(text: "hello"),
                                    fromUserId: "peer", fromDeviceId: "peerdev", ts: 100)
        // the socket got there first and wrote the message
        try device.db.write { dbc in
            var msg = Message(id: "m1", chatId: "c1", fromUserId: "peer", sentAt: 1,
                              kind: .text, text: "hello", status: .sent, isOutgoing: false)
            msg.seq = 1
            try msg.save(dbc)
        }

        _ = try resolve(device, items: [item(1)], envelopes: ["c1/1": envelope])

        let rows = try device.db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = 'c1' AND seq = 1")
        }
        XCTAssertEqual(rows, 1)
    }

    /// Two pushes for one message — the burst window and a redelivery — write
    /// the message once and produce one banner.
    func testSecondPushOfTheSameMessageChangesNothing() throws {
        let device = try makeDevice()
        defer { TestStorage.remove(device.location) }
        try seedChat(device.db)
        var peer = try RatchetPair(store: device.store)
        let envelope = PushEnvelope(body: try peer.envelope(text: "twice"),
                                    fromUserId: "peer", fromDeviceId: "peerdev", ts: 100)

        let first = try resolve(device, items: [item(1)], envelopes: ["c1/1": envelope])
        let second = try resolve(device, items: [item(1)], envelopes: ["c1/1": envelope])

        XCTAssertEqual(first.steps.first?.outcome, .show)
        XCTAssertEqual(second.steps.first?.outcome, .skip(.duplicate))
        let count = try device.db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = 'c1'")
        }
        XCTAssertEqual(count, 1)
        let text = try device.db.read { dbc in
            try String.fetchOne(dbc, sql: "SELECT text FROM message WHERE chatId = 'c1' AND seq = 1")
        }
        XCTAssertEqual(text, "twice")
    }

    /// An envelope that does not open is kept whole: it is the only copy the
    /// device has, and the app replays it when the key arrives.
    func testUnopenableEnvelopeIsKeptForTheApp() throws {
        let device = try makeDevice()
        defer { TestStorage.remove(device.location) }
        try seedChat(device.db)
        // a chat whose sender key never arrived: nothing here can open this
        var env = Envelope(mode: "skm")
        env.c = Data("nonsense".utf8).base64EncodedString()
        env.keyId = "k1"
        env.iteration = 0
        env.sig = Data("sig".utf8).base64EncodedString()
        let body = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(env))
        let envelope = PushEnvelope(body: body, fromUserId: "peer", fromDeviceId: "peerdev", ts: 100)

        let plan = try resolve(device, items: [item(1)], envelopes: ["c1/1": envelope])

        // no message to show: the push keeps the neutral text it arrived with
        XCTAssertEqual(plan.steps.first?.outcome, .show)
        XCTAssertNil(plan.steps.first?.content)
        let pending = try device.db.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT reason, attempts FROM pendingDecrypt WHERE chatId = 'c1' AND seq = 1")
        }
        XCTAssertEqual(pending?["reason"], "no_sender_key")
        XCTAssertEqual(pending?["attempts"], 1)
    }

    /// A chat this device does not know about yet: the message has nowhere to
    /// go, and nothing is invented for it.
    func testMessageForAnUnknownChatIsNotStored() throws {
        let device = try makeDevice()
        defer { TestStorage.remove(device.location) }
        var peer = try RatchetPair(store: device.store)
        let envelope = PushEnvelope(body: try peer.envelope(text: "who is this"),
                                    fromUserId: "peer", fromDeviceId: "peerdev", ts: 100)

        _ = try resolve(device, items: [item(1)], envelopes: ["c1/1": envelope])

        let count = try device.db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message")
        }
        XCTAssertEqual(count, 0)
    }

    /// A burst: three messages arrive as pushes, all three end up in the chat,
    /// in order, and the cursor stands at the top of them.
    func testBurstOfPushesFillsTheChat() throws {
        let device = try makeDevice()
        defer { TestStorage.remove(device.location) }
        try seedChat(device.db)
        var peer = try RatchetPair(store: device.store)
        var envelopes: [String: PushEnvelope] = [:]
        for seq in 1...3 {
            envelopes[Message.feedId(chatId: "c1", seq: seq)] = PushEnvelope(body: try peer.envelope(text: "line \(seq)"),
                                                fromUserId: "peer", fromDeviceId: "peerdev",
                                                ts: Double(seq))
        }

        let plan = try resolve(device, items: [item(3), item(1), item(2)], envelopes: envelopes)

        XCTAssertEqual(plan.shown.map(\.seq), [1, 2, 3])
        let texts = try device.db.read { dbc in
            try String.fetchAll(dbc, sql: "SELECT text FROM message WHERE chatId = 'c1' ORDER BY seq")
        }
        XCTAssertEqual(texts, ["line 1", "line 2", "line 3"])
        let chat = try device.db.read { dbc in try Chat.fetchOne(dbc, key: "c1") }
        XCTAssertEqual(chat?.lastSeq, 3)
        XCTAssertEqual(chat?.syncedSeq, 3)
    }

    /// The journal says what happened to every push: the hardware run reads it
    /// to tell a banner that was shown from one that was also kept.
    func testJournalRecordsWhatWasStored() throws {
        let device = try makeDevice()
        defer { TestStorage.remove(device.location) }
        try seedChat(device.db)
        var peer = try RatchetPair(store: device.store)
        let envelope = PushEnvelope(body: try peer.envelope(text: "written down"),
                                    fromUserId: "peer", fromDeviceId: "peerdev", ts: 100)
        let journal = NotificationJournal(url: device.location.nseJournalURL)

        _ = try resolve(device, items: [item(1)], envelopes: ["c1/1": envelope], journal: journal)

        let entries = journal.entries().filter { $0.phase == .stored }
        XCTAssertEqual(entries.map(\.detail), [PushStoreOutcome.stored.rawValue])
        XCTAssertEqual(entries.first?.chatId, "c1")
    }

    /// A message written by the other process reaches the screens: an
    /// observation hears only its own process, so coming back to the screen is
    /// where the app is told to look at the file again.
    func testForegroundShowsWhatTheOtherProcessWrote() async throws {
        let device = try makeDevice()
        defer { TestStorage.remove(device.location) }
        try seedChat(device.db)
        let api = APIClient(baseURL: URL(string: "http://localhost:1")!)
        let e2ee = E2EEManager(store: device.store, api: api, ownUserId: "me", ownDeviceId: "dev")
        let engine = SyncEngine(db: device.db, api: api, e2ee: e2ee,
                                wsURL: URL(string: "ws://localhost:1/ws")!,
                                ownUserId: "me", ownDeviceId: "dev")

        let empty = expectation(description: "the feed starts empty")
        let seen = expectation(description: "the feed sees the message")
        let cancellable = ValueObservation
            .tracking { dbc in try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message") ?? 0 }
            .start(in: device.db, onError: { _ in }) { count in
                if count == 0 { empty.fulfill() }
                if count == 1 { seen.fulfill() }
            }
        defer { cancellable.cancel() }
        // the observation is running and has read an empty chat: what it sees
        // next can only come from being told to look again
        await fulfillment(of: [empty], timeout: 5)

        // the other process — the extension — writes into the same file
        let other = try AppDatabase.open(at: device.location.databaseURL)
        try await other.write { dbc in
            var msg = Message(id: "m1", chatId: "c1", fromUserId: "peer", sentAt: 1,
                              kind: .text, text: "from the extension", status: .sent,
                              isOutgoing: false)
            msg.seq = 1
            try msg.save(dbc)
        }

        await engine.appBecameActive()
        await fulfillment(of: [seen], timeout: 5)
    }

    /// The app is holding an envelope it could not open, and the extension has
    /// since stored that very message from its push. The envelope is dropped
    /// instead of being retried: the ratchet moved with the extension's step,
    /// and the sweep would otherwise chase a message that is not missing.
    func testEnvelopeOfAnAlreadyStoredMessageIsDropped() async throws {
        let device = try makeDevice()
        defer { TestStorage.remove(device.location) }
        try seedChat(device.db)
        let api = APIClient(baseURL: URL(string: "http://localhost:1")!)
        let e2ee = E2EEManager(store: device.store, api: api, ownUserId: "me", ownDeviceId: "dev")
        let engine = SyncEngine(db: device.db, api: api, e2ee: e2ee,
                                wsURL: URL(string: "ws://localhost:1/ws")!,
                                ownUserId: "me", ownDeviceId: "dev")
        try await device.db.write { dbc in
            var msg = Message(id: "m1", chatId: "c1", fromUserId: "peer", sentAt: 1,
                              kind: .text, text: "already here", status: .sent, isOutgoing: false)
            msg.seq = 1
            try msg.save(dbc)
            try SyncEngine.deferEnvelope(dbc, reason: "no_session", chatId: "c1",
                                         seq: 1, from: "peer", fromDevice: "peerdev", sentAt: 1,
                                         ts: 1, body: Data("{}".utf8), now: 0)
        }

        await engine.sweepUnreadable()

        let left = try await device.db.read { dbc in
            (pending: try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM pendingDecrypt") ?? 0,
             gaps: try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM historyGap") ?? 0)
        }
        XCTAssertEqual(left.pending, 0)
        XCTAssertEqual(left.gaps, 0)
    }

    private func resolve(_ device: Device, items: [BurstItem],
                         envelopes: [String: PushEnvelope],
                         journal: NotificationJournal? = nil) throws -> BurstPlan {
        try device.gate.withLock { ticket in
            let writer = PushMessageWriter(decryptor: device.decryptor, store: device.store,
                                           ownUserId: "me", holding: ticket)
            return try NotificationBurstStore.resolve(db: device.db, items: items,
                                                      showsMessageText: true,
                                                      envelopes: envelopes, writer: writer,
                                                      journal: journal)
        }
    }
}
