import XCTest
import GRDB
@testable import MsngrCore

/// Clearing a chat and deleting it. Both drop rows the cursors were counted
/// over, so what these tests watch is the cursors: `syncedSeq` moves only along
/// a contiguous prefix, the unread count is derived from `lastSeq - myReadUpTo`,
/// and neither may end up asking the server to replay a journal whose keys the
/// ratchet has already destroyed.
final class ChatCleanupTests: XCTestCase {
    private func seedChat(_ db: DatabaseQueue, id: String = "c1", lastSeq: Int,
                          syncedSeq: Int, syncCursor: Int = 0, myReadUpTo: Int = 0) throws {
        var chat = Chat(id: id, kind: .direct, title: nil, createdBy: "peer", createdAt: 0,
                        lastSeq: lastSeq, syncedSeq: syncedSeq, lastActivityAt: 0)
        chat.syncCursor = syncCursor
        chat.myReadUpTo = myReadUpTo
        chat.unreadCount = max(0, lastSeq - myReadUpTo)
        try db.write { dbc in try chat.save(dbc) }
    }

    private func seedMessages(_ db: DatabaseQueue, chatId: String = "c1", seqs: [Int]) throws {
        try db.write { dbc in
            for seq in seqs {
                var msg = Message(id: "m\(seq)", chatId: chatId, fromUserId: "peer", sentAt: Double(seq),
                                  kind: .text, text: "message \(seq)", status: .sent, isOutgoing: false)
                msg.msgId = "m\(seq)"
                msg.seq = seq
                try msg.save(dbc)
            }
        }
    }

    private func count(_ db: DatabaseQueue, _ table: String, chatId: String = "c1") throws -> Int {
        try db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM \(table) WHERE chatId = ?",
                             arguments: [chatId]) ?? 0
        }
    }

    // MARK: - Clearing

    /// The rows go, the position in the journal stays. A rewound cursor would
    /// send the catch-up back over messages this device can no longer read.
    func testClearingKeepsTheCursorsWhereTheyStand() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, lastSeq: 40, syncedSeq: 40, syncCursor: 40, myReadUpTo: 30)
        try seedMessages(db, seqs: Array(1...40))

        try db.write { dbc in try ChatCleanup.clearHistory(dbc, chatId: "c1") }

        let chat = try db.read { dbc in try Chat.fetchOne(dbc, key: "c1") }
        XCTAssertEqual(try count(db, "message"), 0)
        XCTAssertEqual(chat?.lastSeq, 40)
        XCTAssertEqual(chat?.syncedSeq, 40)
        XCTAssertEqual(chat?.syncCursor, 40)
        // ничего не осталось непрочитанного: производный счётчик обнуляется
        // движением отметки, а не записью числа
        XCTAssertEqual(chat?.myReadUpTo, 40)
        XCTAssertEqual(chat?.unreadCount, 0)
        let cursors = try db.read { dbc in try HistoryWindow.catchupCursors(dbc) }
        XCTAssertEqual(cursors["c1"], 40)
    }

    /// A seq that never produced a message here keeps its record, so upward
    /// pagination does not go asking the server for it again.
    func testClearingLeavesTheRecordOfSeqsThatProducedNoMessage() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, lastSeq: 10, syncedSeq: 4, syncCursor: 10, myReadUpTo: 10)
        try seedMessages(db, seqs: [1, 2, 3, 4, 6, 7, 8, 9, 10])
        try db.write { dbc in
            try HistoryWindow.recordGap(dbc, chatId: "c1", seq: 5, reason: "no_session")
        }
        let before = try db.read { dbc in try HistoryWindow.openGaps(dbc, chatId: "c1") }
        XCTAssertTrue(before.isEmpty)

        try db.write { dbc in try ChatCleanup.clearHistory(dbc, chatId: "c1") }

        // запись о пропущенном seq на месте, а сообщения выше застрявшего
        // префикса закрыты собственной записью — иначе они снова стали бы
        // «непрочитанным» диапазоном для сервера
        let after = try db.read { dbc in try HistoryWindow.openGaps(dbc, chatId: "c1") }
        XCTAssertTrue(after.isEmpty, "cleared chat must not reopen a seq range for the server")
        let reasons = try db.read { dbc in
            try String.fetchAll(dbc, sql: "SELECT reason FROM historyGap WHERE chatId = 'c1' ORDER BY seq")
        }
        XCTAssertEqual(reasons, ["no_session", "cleared", "cleared", "cleared", "cleared", "cleared"])
        // молчаливые причины заглушку в ленте не рисуют
        let shown = try db.read { dbc in
            try HistoryWindow.exhaustedGapSeqs(dbc, chatId: "c1", floor: nil)
        }
        XCTAssertTrue(shown.isEmpty)
    }

    /// An unsent message goes with the rest: the user asked for the chat to be
    /// empty, and an outbox row pointing at a message that no longer exists
    /// would send a bubble nobody can see.
    func testClearingTakesTheOutboxOfThatChatOnly() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, lastSeq: 2, syncedSeq: 2)
        try seedChat(db, id: "c2", lastSeq: 1, syncedSeq: 1)
        try db.write { dbc in
            try OutboxItem(clientMsgId: "o1", chatId: "c1", createdAt: 1, payload: Data("{}".utf8)).save(dbc)
            try OutboxItem(clientMsgId: "o2", chatId: "c2", createdAt: 1, payload: Data("{}".utf8)).save(dbc)
            try dbc.execute(sql: """
                INSERT INTO pendingDecrypt (chatId, msgId, seq, fromUserId, fromDevice, sentAt, ts, body)
                VALUES ('c1','m9',9,'peer','d1',0,0,X'7B7D')
                """)
            try SyncEngine.bufferPendingApply(dbc, chatId: "c1", targetMsgId: "m9", kind: "edit",
                                              fromUserId: "peer", payload: "{}", seq: 9)
        }

        try db.write { dbc in try ChatCleanup.clearHistory(dbc, chatId: "c1") }

        XCTAssertEqual(try count(db, "outbox"), 0)
        XCTAssertEqual(try count(db, "outbox", chatId: "c2"), 1)
        XCTAssertEqual(try count(db, "pendingDecrypt"), 0)
        XCTAssertEqual(try count(db, "pendingApply"), 0)
    }

    /// A message arriving right after the clear continues the prefix instead of
    /// restarting it.
    func testMessageArrivingAfterAClearContinuesThePrefix() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, lastSeq: 12, syncedSeq: 12, syncCursor: 12, myReadUpTo: 12)
        try seedMessages(db, seqs: Array(1...12))

        try db.write { dbc in
            try ChatCleanup.clearHistory(dbc, chatId: "c1")
            try SyncEngine.advanceChat(dbc, chatId: "c1", seq: 13, isOwn: false, isService: false)
        }

        let chat = try db.read { dbc in try Chat.fetchOne(dbc, key: "c1") }
        XCTAssertEqual(chat?.syncedSeq, 13)
        XCTAssertEqual(chat?.lastSeq, 13)
        XCTAssertEqual(chat?.unreadCount, 1)
    }

    /// The window has nothing to stand on after a clear, and the next page down
    /// is nothing at all.
    func testClearedChatHasNoWindow() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, lastSeq: 5, syncedSeq: 5)
        try seedMessages(db, seqs: Array(1...5))

        try db.write { dbc in try ChatCleanup.clearHistory(dbc, chatId: "c1") }

        try db.read { dbc in
            XCTAssertNil(try HistoryWindow.newestFloor(dbc, chatId: "c1", limit: 60))
            XCTAssertFalse(try HistoryWindow.hasOlder(dbc, chatId: "c1", floor: nil))
            XCTAssertTrue(try HistoryWindow.messages(dbc, chatId: "c1", floor: nil).isEmpty)
        }
    }

    // MARK: - Deleting

    func testDeletingTakesEverythingTheChatOwns() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, lastSeq: 7, syncedSeq: 7, syncCursor: 7)
        try seedMessages(db, seqs: Array(1...7))
        try db.write { dbc in
            try ChatMemberRow(chatId: "c1", userId: "peer", role: "member", joinedAt: 0).save(dbc)
            try OutboxItem(clientMsgId: "o1", chatId: "c1", createdAt: 1, payload: Data("{}".utf8)).save(dbc)
            try HistoryWindow.recordGap(dbc, chatId: "c1", seq: 8, reason: "no_session")
            try dbc.execute(sql: """
                INSERT INTO senderKeyIn (chatId, senderUserId, keyId, state)
                VALUES ('c1','peer','k1',X'00')
                """)
            try dbc.execute(sql: "INSERT INTO senderKeyOut (chatId, state) VALUES ('c1', X'00')")
        }

        try db.write { dbc in try ChatCleanup.deleteChat(dbc, chatId: "c1") }

        for table in ["message", "outbox", "member", "historyGap", "senderKeyIn", "senderKeyOut"] {
            XCTAssertEqual(try count(db, table), 0, "\(table) still holds rows of the deleted chat")
        }
        let chat = try db.read { dbc in try Chat.fetchOne(dbc, key: "c1") }
        XCTAssertNil(chat)
    }

    /// A direct chat comes back when the peer writes again. It comes back from
    /// where its journal was left, not from the beginning: everything below the
    /// mark was read on this device once and can never be read again.
    func testChatComingBackResumesFromItsTombstone() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, lastSeq: 120, syncedSeq: 120, syncCursor: 120, myReadUpTo: 100)
        try seedMessages(db, seqs: Array(1...120))

        try db.write { dbc in try ChatCleanup.deleteChat(dbc, chatId: "c1") }
        XCTAssertEqual(try db.read { dbc in try ChatCleanup.tombstoneSeq(dbc, chatId: "c1") }, 120)

        // сообщение от собеседника вернуло чат: снапшот отдаёт его состояние
        let state = ChatStateDTO(
            chatId: "c1", kind: "direct", title: nil, avatarId: nil, description: nil,
            createdBy: "peer", createdAt: 1,
            members: [.init(userId: "me", role: "member", joinedAt: 1, accepted: true),
                      .init(userId: "peer", role: "member", joinedAt: 1, accepted: true)],
            pinnedMsgId: nil, lastSeq: 121, readMarks: ["me": 100], deliveredMarks: [:])
        try db.write { dbc in
            try SyncEngine.upsertChatState(dbc, state, ownUserId: "me", flags: nil)
        }

        let chat = try db.read { dbc in try Chat.fetchOne(dbc, key: "c1") }
        XCTAssertEqual(chat?.syncedSeq, 120)
        XCTAssertEqual(chat?.syncCursor, 120)
        // 20 сообщений, которых на устройстве уже нет, в счётчик не идут
        XCTAssertEqual(chat?.myReadUpTo, 120)
        XCTAssertEqual(chat?.unreadCount, 1)
        let cursors = try db.read { dbc in try HistoryWindow.catchupCursors(dbc) }
        XCTAssertEqual(cursors["c1"], 120, "the returning chat must not replay its journal")
        let gaps = try db.read { dbc in try HistoryWindow.openGaps(dbc, chatId: "c1") }
        XCTAssertEqual(gaps, [121...121])
    }

    /// A deleted direct chat keeps its membership on the server, so events
    /// about it still arrive. A pin or a title does not put it back on the
    /// list; a message does, and that path goes through the snapshot.
    func testChatEventDoesNotBringADeletedChatBack() async throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, lastSeq: 4, syncedSeq: 4)
        try await db.write { dbc in try ChatCleanup.deleteChat(dbc, chatId: "c1") }

        let engine = try makeEngine(db: db)
        let json = """
        {"t":"chat","chatId":"c1","event":"pinned","state":{"chatId":"c1","kind":"direct",
        "title":null,"avatarId":null,"description":null,"createdBy":"peer","createdAt":1,
        "members":[{"userId":"me","role":"member","joinedAt":1,"accepted":true},
        {"userId":"peer","role":"member","joinedAt":1,"accepted":true}],
        "pinnedMsgId":"m2","lastSeq":4,"readMarks":{},"deliveredMarks":{}}}
        """
        await engine.apply(try JSONDecoder().decode(WSIncoming.self, from: Data(json.utf8)))

        let chat = try await db.read { dbc in try Chat.fetchOne(dbc, key: "c1") }
        XCTAssertNil(chat, "an event about a deleted chat must not recreate it")
    }

    /// A group this device left and was taken back into is a membership
    /// change, and that one does bring the chat back.
    func testMembershipChangeTakesAGroupBackIn() async throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, lastSeq: 9, syncedSeq: 9)
        try await db.write { dbc in try ChatCleanup.deleteChat(dbc, chatId: "c1") }

        let engine = try makeEngine(db: db)
        let json = """
        {"t":"chat","chatId":"c1","event":"members","state":{"chatId":"c1","kind":"group",
        "title":"Team","avatarId":null,"description":null,"createdBy":"peer","createdAt":1,
        "members":[{"userId":"me","role":"member","joinedAt":50,"accepted":true},
        {"userId":"peer","role":"admin","joinedAt":1,"accepted":true}],
        "pinnedMsgId":null,"lastSeq":30,"readMarks":{},"deliveredMarks":{}}}
        """
        await engine.apply(try JSONDecoder().decode(WSIncoming.self, from: Data(json.utf8)))

        let chat = try await db.read { dbc in try Chat.fetchOne(dbc, key: "c1") }
        XCTAssertNotNil(chat)
        XCTAssertEqual(chat?.syncedSeq, 9, "history from before the group was left stays closed")
    }

    private func makeEngine(db: DatabaseQueue) throws -> SyncEngine {
        let api = APIClient(baseURL: URL(string: "http://localhost:1")!)
        let store = try IdentityStore(db: db, masterKeyProvider: StaticMasterKey())
        let e2ee = E2EEManager(store: store, api: api, ownUserId: "me", ownDeviceId: "dev")
        return SyncEngine(db: db, api: api, e2ee: e2ee,
                          wsURL: URL(string: "ws://localhost:1/ws")!,
                          ownUserId: "me", ownDeviceId: "dev")
    }

    /// A chat this device never deleted starts where it always did.
    func testChatWithoutATombstoneStartsAtZero() throws {
        let db = try AppDatabase.openInMemory()
        let state = ChatStateDTO(
            chatId: "fresh", kind: "direct", title: nil, avatarId: nil, description: nil,
            createdBy: "peer", createdAt: 1,
            members: [.init(userId: "me", role: "member", joinedAt: 1, accepted: true)],
            pinnedMsgId: nil, lastSeq: 4, readMarks: [:], deliveredMarks: [:])
        try db.write { dbc in
            try SyncEngine.upsertChatState(dbc, state, ownUserId: "me", flags: nil)
        }
        let chat = try db.read { dbc in try Chat.fetchOne(dbc, key: "fresh") }
        XCTAssertEqual(chat?.syncedSeq, 0)
        XCTAssertEqual(chat?.syncCursor, 0)
        XCTAssertEqual(chat?.unreadCount, 4)
    }
}
