import XCTest
import GRDB
@testable import MsngrCore

/// A reaction that arrives by push leaves no message row: the extension builds
/// the banner from the payload it applied, and only for a reaction set on a
/// message this user wrote.
final class ReactionPushTests: XCTestCase {
    private let me = "me"
    private let peer = "peer"

    private func seed(_ db: DatabaseQueue, kind: ChatKind = .direct, isRequest: Bool = false) throws {
        try db.write { dbc in
            var chat = Chat(id: "c1", kind: kind, title: kind == .group ? "Team" : nil,
                            createdBy: peer, createdAt: 0, lastSeq: 2, syncedSeq: 2, lastActivityAt: 0)
            chat.isRequest = isRequest
            chat.iAccepted = !isRequest
            try chat.save(dbc)
            try dbc.execute(sql: "INSERT INTO user (id, username, displayName) VALUES (?,?,?)",
                            arguments: [peer, "peer", "Anna"])
            var mine = Message(id: "m1", chatId: "c1", fromUserId: me, sentAt: 1, kind: .text,
                               text: "my line", status: .sent, isOutgoing: true)
            mine.seq = 1
            try mine.save(dbc)
            var theirs = Message(id: "m2", chatId: "c1", fromUserId: peer, sentAt: 2, kind: .photo,
                                 text: nil, status: .sent, isOutgoing: false)
            theirs.seq = 2
            try theirs.save(dbc)
        }
    }

    private func reaction(_ emoji: String?, on target: Int) -> ContentPayload {
        var p = ContentPayload(kind: "reaction")
        p.emoji = emoji
        p.targetSeq = target
        return p
    }

    private func content(_ db: DatabaseQueue, _ payload: ContentPayload, from: String? = "peer",
                         showsText: Bool = true) throws -> NotificationBurstStore.BurstContent {
        try db.read { dbc in
            let chat = try Chat.fetchOne(dbc, key: "c1")
            return try NotificationBurstStore.content(
                dbc, item: BurstItem(chatId: "c1", seq: 3, sentAt: 3), chat: chat,
                showsMessageText: showsText, applied: payload, appliedFrom: from, ownUserId: me)
        }
    }

    func testReactionOnMyMessageNamesTheSenderAndQuotesTheLine() throws {
        let db = try AppDatabase.openInMemory()
        try seed(db)
        guard case .built(let built) = try content(db, reaction("👍", on: 1)) else {
            return XCTFail("a reaction on my message is announced")
        }
        XCTAssertEqual(built.title, "Anna")
        XCTAssertTrue(built.body.contains("👍"), built.body)
        XCTAssertTrue(built.body.contains("my line"), built.body)
        XCTAssertEqual(built.sender?.userId, peer)
    }

    func testReactionOnSomebodyElsesMessageIsSilent() throws {
        let db = try AppDatabase.openInMemory()
        try seed(db)
        XCTAssertEqual(try content(db, reaction("👍", on: 2)), .silent)
    }

    func testClearedReactionIsSilent() throws {
        let db = try AppDatabase.openInMemory()
        try seed(db)
        XCTAssertEqual(try content(db, reaction(nil, on: 1)), .silent)
    }

    func testReactionOnAMessageThisDeviceDoesNotHoldIsSilent() throws {
        let db = try AppDatabase.openInMemory()
        try seed(db)
        XCTAssertEqual(try content(db, reaction("👍", on: 9)), .silent)
    }

    func testRequestChatHidesReactions() throws {
        let db = try AppDatabase.openInMemory()
        try seed(db, isRequest: true)
        XCTAssertEqual(try content(db, reaction("👍", on: 1)), .silent)
    }

    func testGroupReactionCarriesTheRoster() throws {
        let db = try AppDatabase.openInMemory()
        try seed(db, kind: .group)
        try db.write { dbc in
            for id in [me, peer] {
                try ChatMemberRow(chatId: "c1", userId: id, role: "member", joinedAt: 0).save(dbc)
            }
        }
        guard case .built(let built) = try content(db, reaction("❤️", on: 1)) else {
            return XCTFail("a group reaction on my message is announced")
        }
        XCTAssertEqual(built.subtitle, "Team")
        XCTAssertEqual(Set(built.groupMembers.map(\.userId)), [me, peer])
    }

    func testHiddenTextKeepsTheEmojiAndDropsTheQuote() throws {
        let db = try AppDatabase.openInMemory()
        try seed(db)
        guard case .built(let built) = try content(db, reaction("👍", on: 1), showsText: false) else {
            return XCTFail("announced")
        }
        XCTAssertFalse(built.body.contains("my line"), built.body)
    }
}
