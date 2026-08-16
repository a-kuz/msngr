import XCTest
import GRDB
@testable import MsngrCore

/// What the author is told about his message: the receipt the recipient owes,
/// and the tick that receipt turns into.
final class DeliveryReceiptTests: XCTestCase {
    private func makeEngine(db: DatabaseQueue) throws -> SyncEngine {
        let api = APIClient(baseURL: URL(string: "http://localhost:1")!)
        let store = try IdentityStore(db: db, masterKeyProvider: StaticMasterKey())
        let e2ee = E2EEManager(store: store, api: api, ownUserId: "me", ownDeviceId: "dev")
        return SyncEngine(db: db, api: api, e2ee: e2ee,
                          wsURL: URL(string: "ws://localhost:1/ws")!,
                          ownUserId: "me", ownDeviceId: "dev")
    }

    /// A chat with the given members and one outgoing message per seq.
    private func seedChat(_ db: DatabaseQueue, members: [String], seqs: [Int],
                          kind: ChatKind = .group) throws {
        try db.write { dbc in
            var chat = Chat(id: "c1", kind: kind, title: "Chat", createdBy: "me", createdAt: 0,
                            lastSeq: seqs.max() ?? 0, syncedSeq: seqs.max() ?? 0, lastActivityAt: 0)
            chat.myReadUpTo = seqs.max() ?? 0
            try chat.save(dbc)
            for userId in members + ["me"] {
                try ChatMemberRow(chatId: "c1", userId: userId, role: "member", joinedAt: 0).save(dbc)
            }
            for seq in seqs {
                var msg = Message(id: "cm\(seq)", chatId: "c1", fromUserId: "me", sentAt: Double(seq),
                                  kind: .text, text: "hi", status: .sent, isOutgoing: true)
                msg.msgId = "m\(seq)"
                msg.clientMsgId = "cm\(seq)"
                msg.seq = seq
                try msg.save(dbc)
            }
        }
    }

    private func receipt(_ kind: String, by: String, upToSeq: Int) throws -> WSIncoming {
        let json = #"{"t":"receipt","chatId":"c1","kind":"\#(kind)","upToSeq":\#(upToSeq),"by":"\#(by)"}"#
        return try JSONDecoder().decode(WSIncoming.self, from: Data(json.utf8))
    }

    private func status(_ db: DatabaseQueue, seq: Int) async throws -> MessageStatus? {
        try await db.read { dbc in
            try Message.fetchOne(dbc, sql: "SELECT * FROM message WHERE seq = ?", arguments: [seq])?.status
        }
    }

    // MARK: - The tick in a group

    /// The tick speaks for the whole chat: one member out of two answering
    /// leaves it where it was, and the second one moves it.
    func testDeliveredWaitsForTheLastMember() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try seedChat(db, members: ["b", "c"], seqs: [1])

        await engine.apply(try receipt("delivered", by: "b", upToSeq: 1))
        let afterOne = try await status(db, seq: 1)
        XCTAssertEqual(afterOne, .sent, "one member of two is not the whole chat")

        await engine.apply(try receipt("delivered", by: "c", upToSeq: 1))
        let afterBoth = try await status(db, seq: 1)
        XCTAssertEqual(afterBoth, .delivered)
    }

    func testReadWaitsForTheLastMember() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try seedChat(db, members: ["b", "c"], seqs: [1])

        await engine.apply(try receipt("read", by: "b", upToSeq: 1))
        await engine.apply(try receipt("delivered", by: "c", upToSeq: 1))
        XCTAssertEqual(try await status(db, seq: 1), .delivered)

        await engine.apply(try receipt("read", by: "c", upToSeq: 1))
        XCTAssertEqual(try await status(db, seq: 1), .read)
    }

    /// Reading is having received: a read mark alone moves the delivered tick
    /// of a direct chat, whose peer never sent a separate `recv`.
    func testReadImpliesDelivered() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try seedChat(db, members: ["b"], seqs: [1], kind: .direct)

        await engine.apply(try receipt("read", by: "b", upToSeq: 1))

        XCTAssertEqual(try await status(db, seq: 1), .read)
        let chat = try await db.read { dbc in try Chat.fetchOne(dbc, key: "c1") }
        XCTAssertEqual(chat?.peerDeliveredUpTo, 1)
    }

    /// A receipt that only reaches part of the chat leaves the newer message
    /// alone: the marks are per seq, not per chat.
    func testMarkCoversOnlyWhatItNames() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try seedChat(db, members: ["b"], seqs: [1, 2], kind: .direct)

        await engine.apply(try receipt("delivered", by: "b", upToSeq: 1))

        XCTAssertEqual(try await status(db, seq: 1), .delivered)
        XCTAssertEqual(try await status(db, seq: 2), .sent)
    }

    /// Our own mark from another device says nothing about the peer.
    func testOwnReceiptIsIgnored() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try seedChat(db, members: ["b"], seqs: [1], kind: .direct)

        await engine.apply(try receipt("read", by: "me", upToSeq: 1))

        XCTAssertEqual(try await status(db, seq: 1), .sent)
    }

    /// Someone joining a group later has no marks of his own, and the ticks
    /// already given out stay where they are.
    func testNewMemberDoesNotTakeTheTickBack() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try seedChat(db, members: ["b"], seqs: [1])
        await engine.apply(try receipt("read", by: "b", upToSeq: 1))
        XCTAssertEqual(try await status(db, seq: 1), .read)

        try await db.write { dbc in
            try ChatMemberRow(chatId: "c1", userId: "c", role: "member", joinedAt: 5).save(dbc)
            try SyncEngine.applyPeerMarks(dbc, chatId: "c1", ownUserId: "me")
        }

        XCTAssertEqual(try await status(db, seq: 1), .read)
        let chat = try await db.read { dbc in try Chat.fetchOne(dbc, key: "c1") }
        XCTAssertEqual(chat?.peerReadUpTo, 1)
    }

    // MARK: - The receipt this device owes

    /// One row per chat, holding the seq furthest along: a receipt is a mark,
    /// not a list.
    func testQueueKeepsTheFurthestSeq() async throws {
        let db = try AppDatabase.openInMemory()
        try await db.write { dbc in
            try DeliveryReceipts.record(dbc, chatId: "c1", upToSeq: 4)
            try DeliveryReceipts.record(dbc, chatId: "c1", upToSeq: 2)
            try DeliveryReceipts.record(dbc, chatId: "c2", upToSeq: 7)
        }

        let pending = try await db.read { dbc in try DeliveryReceipts.pending(dbc) }

        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(pending.first { $0.chatId == "c1" }?.upToSeq, 4)
        XCTAssertEqual(pending.first { $0.chatId == "c2" }?.upToSeq, 7)
    }

    /// A receipt is dropped when the server has taken it, and a larger mark
    /// written meanwhile stays to be sent.
    func testQueueClearsOnlyWhatWasSent() async throws {
        let db = try AppDatabase.openInMemory()
        try await db.write { dbc in try DeliveryReceipts.record(dbc, chatId: "c1", upToSeq: 3) }
        try await db.write { dbc in try DeliveryReceipts.record(dbc, chatId: "c1", upToSeq: 5) }

        try await db.write { dbc in try DeliveryReceipts.clear(dbc, chatId: "c1", upToSeq: 3) }
        let stillThere = try await db.read { dbc in try DeliveryReceipts.pending(dbc) }
        XCTAssertEqual(stillThere.first?.upToSeq, 5)

        try await db.write { dbc in try DeliveryReceipts.clear(dbc, chatId: "c1", upToSeq: 5) }
        let empty = try await db.read { dbc in try DeliveryReceipts.pending(dbc) }
        XCTAssertTrue(empty.isEmpty)
    }

    /// The push is the message reaching the device, so the extension queues the
    /// receipt in the same transaction that writes the message.
    func testBurstQueuesTheReceipt() throws {
        let db = try AppDatabase.openInMemory()
        try db.write { dbc in
            let chat = Chat(id: "c1", kind: .direct, title: nil, createdBy: "peer", createdAt: 0,
                            lastSeq: 0, syncedSeq: 0, lastActivityAt: 0)
            try chat.save(dbc)
        }
        let items = [BurstItem(chatId: "c1", msgId: "m1", seq: 1, sentAt: 1),
                     BurstItem(chatId: "c1", msgId: "m2", seq: 2, sentAt: 2)]

        _ = try NotificationBurstStore.resolve(db: db, items: items, showsMessageText: true)

        let pending = try db.read { dbc in try DeliveryReceipts.pending(dbc) }
        XCTAssertEqual(pending.first?.chatId, "c1")
        XCTAssertEqual(pending.first?.upToSeq, 2)
    }

    /// A request nobody accepted tells its author nothing, not even that his
    /// message arrived.
    func testBurstQueuesNothingForARequest() throws {
        let db = try AppDatabase.openInMemory()
        try db.write { dbc in
            var chat = Chat(id: "c1", kind: .direct, title: nil, createdBy: "peer", createdAt: 0,
                            lastSeq: 0, syncedSeq: 0, lastActivityAt: 0)
            chat.isRequest = true
            chat.iAccepted = false
            try chat.save(dbc)
        }

        _ = try NotificationBurstStore.resolve(
            db: db, items: [BurstItem(chatId: "c1", msgId: "m1", seq: 1, sentAt: 1)],
            showsMessageText: true)

        let pending = try db.read { dbc in try DeliveryReceipts.pending(dbc) }
        XCTAssertTrue(pending.isEmpty)
    }
}
