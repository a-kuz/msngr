import XCTest
import GRDB
@testable import MsngrCore

/// A message that speaks to this user — a mention, or a reply to their
/// message — is flagged for its own sound and gets through a muted chat, in
/// the extension as in the app.
final class MentionPushTests: XCTestCase {
    private let me = "me"
    private let peer = "peer"

    private func seed(_ db: DatabaseQueue, muted: Bool) throws {
        try db.write { dbc in
            var chat = Chat(id: "c1", kind: .group, title: "Team", createdBy: peer, createdAt: 0,
                            lastSeq: 1, syncedSeq: 1, lastActivityAt: 0)
            chat.muted = muted
            try chat.save(dbc)
            try dbc.execute(sql: "INSERT INTO user (id, username, displayName) VALUES (?,?,?)",
                            arguments: [peer, "peer", "Anna"])
            var mine = Message(id: "m1", chatId: "c1", fromUserId: me, sentAt: 1, kind: .text,
                               text: "my line", status: .sent, isOutgoing: true)
            mine.seq = 1
            try mine.save(dbc)
        }
    }

    private func store(_ db: DatabaseQueue, seq: Int, text: String, replyTo: ReplyPreview? = nil) throws {
        try db.write { dbc in
            var msg = Message(id: "m\(seq)", chatId: "c1", fromUserId: peer, sentAt: Double(seq),
                              kind: .text, text: text, status: .sent, isOutgoing: false)
            msg.seq = seq
            msg.replyTo = replyTo
            try msg.save(dbc)
        }
    }

    private func resolve(_ db: DatabaseQueue, seq: Int) throws -> BurstStep? {
        try NotificationBurstStore.resolve(
            db: db, items: [BurstItem(chatId: "c1", seq: seq, sentAt: Double(seq))],
            showsMessageText: true, ownUserId: me).steps.first
    }

    func testMentionInAMutedChatStillShowsAndIsFlagged() throws {
        let db = try AppDatabase.openInMemory()
        try seed(db, muted: true)
        try store(db, seq: 2, text: "hey @[me](user:me), look")
        let step = try resolve(db, seq: 2)
        XCTAssertEqual(step?.outcome, .show)
        XCTAssertEqual(step?.content?.addressedToMe, true)
    }

    func testReplyToMyMessageInAMutedChatStillShows() throws {
        let db = try AppDatabase.openInMemory()
        try seed(db, muted: true)
        try store(db, seq: 2, text: "agreed",
                  replyTo: ReplyPreview(seq: 1, authorId: me, text: "my line", kind: "text"))
        let step = try resolve(db, seq: 2)
        XCTAssertEqual(step?.outcome, .show)
        XCTAssertEqual(step?.content?.addressedToMe, true)
    }

    func testPlainMessageInAMutedChatStaysMuted() throws {
        let db = try AppDatabase.openInMemory()
        try seed(db, muted: true)
        try store(db, seq: 2, text: "nothing for you")
        XCTAssertEqual(try resolve(db, seq: 2)?.outcome, .skip(.muted))
    }

    func testPlainMessageIsNotFlagged() throws {
        let db = try AppDatabase.openInMemory()
        try seed(db, muted: false)
        try store(db, seq: 2, text: "nothing for you")
        let step = try resolve(db, seq: 2)
        XCTAssertEqual(step?.outcome, .show)
        XCTAssertEqual(step?.content?.addressedToMe, false)
    }

    func testMentionSoundPreferenceDefaultsToItsOwnChime() {
        let defaults = UserDefaults(suiteName: "MentionPushTests-\(UUID().uuidString)")!
        XCTAssertEqual(NotificationPreferences.mentionSound(in: defaults),
                       NotificationPreferences.defaultMentionSound)
        NotificationPreferences.setMentionSound("none", in: defaults)
        XCTAssertEqual(NotificationPreferences.mentionSound(in: defaults), "none")
    }
}
