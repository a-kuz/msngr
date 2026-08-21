import XCTest
import GRDB
@testable import MsngrCore

/// The database side of a burst: who owns the right to present a message, what
/// the banner says, and how the hole left by the offline reaches the app.
final class NotificationBurstStoreTests: XCTestCase {
    private func seedChat(_ db: DatabaseQueue, id: String = "c1", lastSeq: Int = 0,
                          syncedSeq: Int = 0, readUpTo: Int = 0, muted: Bool = false,
                          kind: ChatKind = .direct) throws {
        var chat = Chat(id: id, kind: kind, title: kind == .group ? "Group" : nil,
                        createdBy: "peer", createdAt: 0, lastSeq: lastSeq,
                        syncedSeq: syncedSeq, lastActivityAt: 0)
        chat.myReadUpTo = readUpTo
        chat.muted = muted
        try db.write { dbc in try chat.save(dbc) }
    }

    private func seedMessage(_ db: DatabaseQueue, chatId: String = "c1", seq: Int,
                             text: String, from: String = "peer") throws {
        try db.write { dbc in
            var msg = Message(id: "m\(seq)", chatId: chatId, fromUserId: from,
                              sentAt: Double(seq), kind: .text, text: text,
                              status: .sent, isOutgoing: false)
            msg.seq = seq
            try msg.save(dbc)
        }
    }

    private func item(_ seq: Int, chat chatId: String = "c1") -> BurstItem {
        BurstItem(chatId: chatId, seq: seq, sentAt: Double(seq))
    }

    private func resolve(_ db: DatabaseQueue, _ items: [BurstItem]) throws -> BurstPlan {
        try NotificationBurstStore.resolve(db: db, items: items, showsMessageText: true)
    }

    /// The claim is the whole decision: whoever inserts the row presents the
    /// banner, everybody else is answered with nothing.
    func testClaimIsTakenOnce() throws {
        let db = try AppDatabase.openInMemory()
        let taken = try db.write { dbc in
            [try NotificationBurstStore.claim(dbc, chatId: "c1", seq: 1),
             try NotificationBurstStore.claim(dbc, chatId: "c1", seq: 1)]
        }
        XCTAssertEqual(taken, [true, false])
    }

    /// A push for a message whose banner is already out produces nothing —
    /// showing it again would ring for what the user has seen.
    func testSecondPushForTheSameMessageIsSkipped() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db)
        XCTAssertEqual(try resolve(db, [item(1)]).steps.first?.outcome, .show)
        XCTAssertEqual(try resolve(db, [item(1)]).steps.first?.outcome, .skip(.duplicate))
    }

    /// Read on another device while the burst was in flight.
    func testMessageBelowTheReadMarkIsSkipped() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, lastSeq: 4, readUpTo: 4)
        let plan = try resolve(db, [item(3), item(5)])
        XCTAssertEqual(plan.shown.map(\.seq), [5])
        XCTAssertEqual(plan.steps.first { $0.item.seq == 3 }?.outcome, .skip(.read))
    }

    func testMutedChatIsSkipped() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, muted: true)
        XCTAssertEqual(try resolve(db, [item(1)]).steps.first?.outcome, .skip(.muted))
    }

    /// The burst tells the device how far the chat went; the hole it leaves is
    /// what upward pagination asks the server for.
    func testBurstOpensTheHoleForTheApp() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, lastSeq: 5, syncedSeq: 5)
        let plan = try resolve(db, [item(8), item(9)])
        // 6 and 7 were never pushed to this device at all
        XCTAssertEqual(plan.gaps.first?.ranges, [6...7])

        // the extension stores no message rows, so for the app everything above
        // the cursor is still to be fetched
        let open = try db.read { dbc in try HistoryWindow.openGaps(dbc, chatId: "c1") }
        XCTAssertEqual(open, [6...9])
        let cursors = try db.read { dbc in try Chat.fetchOne(dbc, key: "c1")! }
        XCTAssertEqual(cursors.lastSeq, 9)
        XCTAssertEqual(cursors.syncedSeq, 5)
        // unread stays derived from the cursors
        XCTAssertEqual(cursors.unreadCount, 9)
    }

    /// The banner text comes from the message the device stores.
    func testBannerTextComesFromTheStoredMessage() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db)
        try db.write { dbc in
            try User(id: "peer", username: "peer", displayName: "Peer").save(dbc)
        }
        try seedMessage(db, seq: 1, text: "hello there")

        let step = try resolve(db, [item(1)]).steps.first
        XCTAssertEqual(step?.outcome, .show)
        XCTAssertEqual(step?.content?.title, "Peer")
        XCTAssertEqual(step?.content?.body, "hello there")
        XCTAssertEqual(step?.content?.threadIdentifier, "c1")
    }

    /// The message has not been decrypted here yet: the push keeps the neutral
    /// text it arrived with instead of guessing.
    func testUnknownMessageKeepsThePushContent() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db)
        let step = try resolve(db, [item(1)]).steps.first
        XCTAssertEqual(step?.outcome, .show)
        XCTAssertNil(step?.content)
    }

    /// A hundred pushes shuffled by APNs across two chats: every message gets
    /// exactly one banner, in the order the messages were sent.
    func testAvalancheIsPostedOnceEachInOrder() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, id: "c1")
        try seedChat(db, id: "c2")
        var items = (1...50).map { item($0, chat: "c1") } + (1...50).map { item($0, chat: "c2") }
        items.shuffle()

        let plan = try resolve(db, items)
        XCTAssertEqual(plan.shown.count, 100)
        XCTAssertEqual(plan.shown.filter { $0.chatId == "c1" }.map(\.seq), Array(1...50))
        XCTAssertEqual(plan.shown.filter { $0.chatId == "c2" }.map(\.seq), Array(1...50))
        // a repeat delivery of the same burst adds nothing
        XCTAssertTrue(try resolve(db, items).shown.isEmpty)
    }

}
