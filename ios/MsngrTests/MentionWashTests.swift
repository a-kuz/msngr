import XCTest
@testable import Msngr
import MsngrCore

/// A message that mentions this user keeps an accent wash in the feed. The
/// layout plan decides who gets it: an incoming message carrying the token of
/// this user, and nobody else.
final class MentionWashTests: XCTestCase {
    private let width: CGFloat = 390

    override func tearDown() {
        OwnUser.id = ""
        super.tearDown()
    }

    private func message(text: String, outgoing: Bool, deletedForAll: Bool = false) -> Message {
        var m = Message(id: UUID().uuidString, chatId: "c",
                        fromUserId: outgoing ? "me" : "peer",
                        sentAt: 1_700_000_000, kind: .text, text: text,
                        status: .sent, isOutgoing: outgoing)
        m.seq = 1
        m.serverTs = 1_700_000_000
        m.deletedForAll = deletedForAll
        return m
    }

    private func mentionsMe(text: String, outgoing: Bool = false,
                            deletedForAll: Bool = false) -> Bool {
        BubbleLayout.plan(for: message(text: text, outgoing: outgoing,
                                       deletedForAll: deletedForAll),
                          width: width, tightGap: false, showTail: true,
                          showName: false, authorName: nil).mentionsMe
    }

    func testIncomingMentionOfMeIsWashed() {
        OwnUser.id = "u1"
        XCTAssertTrue(mentionsMe(text: "look [@Me](user:u1) here"))
    }

    func testMentionOfSomeoneElseIsNotWashed() {
        OwnUser.id = "u1"
        XCTAssertFalse(mentionsMe(text: "look [@Other](user:u12) here"))
    }

    func testPlainTextIsNotWashed() {
        OwnUser.id = "u1"
        XCTAssertFalse(mentionsMe(text: "nothing to see"))
    }

    /// Your own message quoting your own mention is not a call to you.
    func testOwnMessageIsNotWashed() {
        OwnUser.id = "u1"
        XCTAssertTrue(mentionsMe(text: "[@Me](user:u1)"))
        XCTAssertFalse(mentionsMe(text: "[@Me](user:u1)", outgoing: true))
    }

    /// A deleted message shows a stand-in line, so there is nothing to mark.
    func testDeletedMessageIsNotWashed() {
        OwnUser.id = "u1"
        XCTAssertFalse(mentionsMe(text: "[@Me](user:u1)", deletedForAll: true))
    }

    /// Before bootstrap the id is empty and must match nobody.
    func testNoOwnIdMatchesNothing() {
        OwnUser.id = ""
        XCTAssertFalse(mentionsMe(text: "[@Me](user:u1)"))
    }
}
