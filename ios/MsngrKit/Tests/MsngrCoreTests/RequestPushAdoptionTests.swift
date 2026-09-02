import XCTest
import GRDB
@testable import MsngrCore

/// A push for the first message of a request reaches a device that has no row
/// for the chat or its author. The push names the author, and the extension
/// writes the chat as the request it is, so the banner names the person and
/// hides the text.
final class RequestPushAdoptionTests: XCTestCase {
    private let me = "me"
    private let stranger = "stranger"
    private var chatId: String { "direct:\(me):\(stranger)" }

    func testUnknownDirectChatBecomesARequestNamedAfterItsAuthor() throws {
        let db = try AppDatabase.openInMemory()
        try db.write { dbc in
            let adopted = try NotificationBurstStore.adoptRequestChat(
                dbc, chatId: chatId, from: stranger, fromName: "Delta Service",
                ownUserId: me, sentAt: 1_700_000_000_000)
            XCTAssertTrue(adopted)
        }
        let chat = try db.read { dbc in try Chat.fetchOne(dbc, key: chatId) }
        XCTAssertNotNil(chat)
        XCTAssertTrue(chat?.isRequest ?? false)
        XCTAssertFalse(chat?.iAccepted ?? true)
        XCTAssertTrue(ChatPrivacy.hidesContent(chat))
        let name = try db.read { dbc in
            try String.fetchOne(dbc, sql: "SELECT displayName FROM user WHERE id = ?", arguments: [stranger])
        }
        XCTAssertEqual(name, "Delta Service")
        let members = try db.read { dbc in
            try String.fetchAll(dbc, sql: "SELECT userId FROM member WHERE chatId = ? ORDER BY userId",
                                arguments: [chatId])
        }
        XCTAssertEqual(members, [me, stranger])
    }

    func testTheBannerNamesTheAuthorAndHidesTheText() throws {
        let db = try AppDatabase.openInMemory()
        try db.write { dbc in
            try NotificationBurstStore.adoptRequestChat(
                dbc, chatId: chatId, from: stranger, fromName: "Delta Service",
                ownUserId: me, sentAt: 0)
            var msg = Message(id: "m1", chatId: chatId, fromUserId: stranger, sentAt: 1,
                              kind: .text, text: "knock knock", status: .sent, isOutgoing: false)
            msg.seq = 1
            try msg.save(dbc)
        }
        let plan = try NotificationBurstStore.resolve(
            db: db, items: [BurstItem(chatId: chatId, seq: 1, sentAt: 1)], showsMessageText: true)
        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertEqual(plan.steps.first?.outcome, .show)
        XCTAssertEqual(plan.steps.first?.content?.title, "Delta Service")
        XCTAssertEqual(plan.steps.first?.content?.body, ChatPrivacy.requestPlaceholder)
    }

    func testOnlyADirectChatBetweenTheTwoIsAdopted() throws {
        let db = try AppDatabase.openInMemory()
        try db.write { dbc in
            XCTAssertFalse(try NotificationBurstStore.adoptRequestChat(
                dbc, chatId: "01GROUPID", from: stranger, fromName: "X", ownUserId: me, sentAt: 0))
            XCTAssertFalse(try NotificationBurstStore.adoptRequestChat(
                dbc, chatId: "direct:\(me):somebody", from: stranger, fromName: "X",
                ownUserId: me, sentAt: 0))
            XCTAssertFalse(try NotificationBurstStore.adoptRequestChat(
                dbc, chatId: "direct:\(me):\(me)", from: me, fromName: "X", ownUserId: me, sentAt: 0))
        }
        let count = try db.read { dbc in try Chat.fetchCount(dbc) }
        XCTAssertEqual(count, 0)
    }

    func testAnExistingUserRowKeepsItsCard() throws {
        let db = try AppDatabase.openInMemory()
        try db.write { dbc in
            try dbc.execute(sql: """
                INSERT INTO user (id, username, displayName, bio, avatarId) VALUES (?,?,?,?,?)
                """, arguments: [stranger, "delta", "Delta", "a bio", "av1"])
            try NotificationBurstStore.adoptRequestChat(
                dbc, chatId: chatId, from: stranger, fromName: "Delta Service",
                ownUserId: me, sentAt: 0)
        }
        let row = try db.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT displayName, avatarId FROM user WHERE id = ?", arguments: [stranger])
        }
        XCTAssertEqual(row?["displayName"] as String?, "Delta")
        XCTAssertEqual(row?["avatarId"] as String?, "av1")
    }
}
