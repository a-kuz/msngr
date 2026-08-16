import GRDB
import XCTest
@testable import MsngrCore

/// A device that has just been linked holds the account's chat list and none of
/// its history: the ratchet destroyed the keys of everything said before it
/// existed. What these tests hold to is that it never asks for that history —
/// neither through the catch-up nor through upward pagination — and that it
/// starts with nothing marked unread.
final class DeviceLinkTests: XCTestCase {
    private func chatState(_ id: String, lastSeq: Int, peerRead: Int = 0) -> ChatStateDTO {
        let json = """
        {"chatId":"\(id)","kind":"direct","title":null,"avatarId":null,"description":null,
         "createdBy":"peer","createdAt":1,"pinnedMsgId":null,"lastSeq":\(lastSeq),
         "members":[{"userId":"me","role":"member","joinedAt":1,"accepted":true},
                    {"userId":"peer","role":"member","joinedAt":1,"accepted":true}],
         "readMarks":{"peer":\(peerRead)},"deliveredMarks":{}}
        """
        return try! JSONDecoder().decode(ChatStateDTO.self, from: Data(json.utf8))
    }

    func testALinkedDeviceStartsEveryChatAtItsCurrentEnd() throws {
        let db = try AppDatabase.openInMemory()
        try db.write { dbc in
            try DeviceLink.startChatsFromNow(dbc, chats: [("c1", 40), ("c2", 7)])
            try SyncEngine.upsertChatState(dbc, chatState("c1", lastSeq: 40), ownUserId: "me",
                                           flags: nil)
            try SyncEngine.upsertChatState(dbc, chatState("c2", lastSeq: 7), ownUserId: "me",
                                           flags: nil)
        }
        let chats = try db.read { dbc in try Chat.fetchAll(dbc).sorted { $0.id < $1.id } }
        XCTAssertEqual(chats.map(\.id), ["c1", "c2"])
        XCTAssertEqual(chats[0].syncedSeq, 40)
        XCTAssertEqual(chats[0].syncCursor, 40)
        XCTAssertEqual(chats[0].myReadUpTo, 40)
        XCTAssertEqual(chats[0].unreadCount, 0)
        XCTAssertEqual(chats[1].syncedSeq, 7)
        XCTAssertEqual(chats[1].unreadCount, 0)

        // the catch-up asks only for what comes after the link
        let cursors = try db.read { dbc in try HistoryWindow.catchupCursors(dbc) }
        XCTAssertEqual(cursors, ["c1": 40, "c2": 7])
        // and nothing is behind, so no portion is even requested
        let behind = try db.read { dbc in
            try HistoryWindow.catchupCursors(dbc, behindOnly: true)
        }
        XCTAssertTrue(behind.isEmpty)
    }

    /// Paging up in a chat that starts empty must not go to the server for a
    /// range whose keys this device will never hold.
    func testUpwardPaginationAsksForNothing() throws {
        let db = try AppDatabase.openInMemory()
        try db.write { dbc in
            try DeviceLink.startChatsFromNow(dbc, chats: [("c1", 120)])
            try SyncEngine.upsertChatState(dbc, chatState("c1", lastSeq: 120), ownUserId: "me",
                                           flags: nil)
        }
        let gaps = try db.read { dbc in try HistoryWindow.openGaps(dbc, chatId: "c1") }
        XCTAssertTrue(gaps.isEmpty, "\(gaps)")
        let floor = try db.read { dbc in
            try HistoryWindow.newestFloor(dbc, chatId: "c1", limit: HistoryWindow.pageSize)
        }
        XCTAssertNil(floor)
        let placeholders = try db.read { dbc in
            try HistoryWindow.exhaustedGapSeqs(dbc, chatId: "c1", floor: nil)
        }
        XCTAssertTrue(placeholders.isEmpty, "an empty chat shows no unreadable placeholders")
    }

    /// The next message the peer sends lands normally and moves the cursor by
    /// one, rather than opening a hole back to the start of the journal.
    func testTheFirstMessageAfterLinkingLandsWithoutAHole() throws {
        let db = try AppDatabase.openInMemory()
        try db.write { dbc in
            try DeviceLink.startChatsFromNow(dbc, chats: [("c1", 40)])
            try SyncEngine.upsertChatState(dbc, chatState("c1", lastSeq: 40), ownUserId: "me",
                                           flags: nil)
            try dbc.execute(sql: """
                UPDATE chat SET lastSeq = 41, syncedSeq = 41, unreadCount = 1 WHERE id = 'c1'
                """)
            var msg = Message(id: "m41", chatId: "c1", fromUserId: "peer", sentAt: 41,
                              kind: .text, text: "first one this device sees",
                              status: .sent, isOutgoing: false)
            msg.msgId = "m41"
            msg.seq = 41
            try msg.save(dbc)
        }
        let gaps = try db.read { dbc in try HistoryWindow.openGaps(dbc, chatId: "c1") }
        XCTAssertTrue(gaps.isEmpty, "\(gaps)")
        let window = try db.read { dbc in
            try HistoryWindow.messages(dbc, chatId: "c1", floor: nil)
        }
        XCTAssertEqual(window.map(\.seq), [41])
    }

    /// A chat this device deleted before it was re-listed keeps the later of
    /// the two positions: the mark must not move a cursor backwards.
    func testAnExistingTombstoneIsNotMovedBackwards() throws {
        let db = try AppDatabase.openInMemory()
        try db.write { dbc in
            try dbc.execute(
                sql: "INSERT INTO chatTombstone (chatId, seq, deletedAt) VALUES ('c1', 90, 1)")
            try DeviceLink.startChatsFromNow(dbc, chats: [("c1", 40)])
        }
        let seq = try db.read { dbc in try ChatCleanup.tombstoneSeq(dbc, chatId: "c1") }
        XCTAssertEqual(seq, 90)
    }

    func testCodeIsShownInTwoHalvesAndReadBackLoosely() {
        XCTAssertEqual(DeviceLink.formatCode("K7QP3MTX"), "K7QP-3MTX")
        XCTAssertEqual(DeviceLink.normalizeCode(" k7qp-3mtx "), "K7QP3MTX")
        XCTAssertEqual(DeviceLink.normalizeCode("K7QP 3MTX"), "K7QP3MTX")
    }
}
