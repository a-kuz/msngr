import XCTest
import GRDB
import MsngrCrypto
@testable import MsngrCore

/// A poll travels as its own message kind; votes travel as `pollVote` service
/// frames, aggregate on the poll row, replace the voter's earlier choice, and
/// wait for the poll when they arrive first.
final class PollTests: XCTestCase {
    private func insertPoll(_ db: DatabaseQueue, seq: Int, anonymous: Bool = false) async throws {
        try await db.write { dbc in
            var msg = Message(id: "p\(seq)", chatId: "c1", fromUserId: "peer",
                              sentAt: 100, kind: .poll, text: nil, status: .sent,
                              isOutgoing: false)
            msg.seq = seq
            msg.poll = PollInfo(id: "poll-\(seq)", question: "Lunch?", options: ["Pizza", "Sushi", "Soup"],
                                multiple: false, anonymous: anonymous)
            try msg.save(dbc)
        }
    }

    func testAnonymousVoteIsStoredUnderThePseudonymAndNotTheSender() async throws {
        let db = try AppDatabase.openInMemory()
        try await insertPoll(db, seq: 1, anonymous: true)
        try await db.write { dbc in
            try SyncEngine.applyPollVote(dbc, chatId: "c1", targetSeq: 1,
                                         userId: "peer", votes: [0], voter: "anon:aa")
            try SyncEngine.applyPollVote(dbc, chatId: "c1", targetSeq: 1,
                                         userId: "me", votes: [2], voter: "anon:bb")
            // the same pseudonym again replaces, an empty choice retracts
            try SyncEngine.applyPollVote(dbc, chatId: "c1", targetSeq: 1,
                                         userId: "peer", votes: [1], voter: "anon:aa")
            try SyncEngine.applyPollVote(dbc, chatId: "c1", targetSeq: 1,
                                         userId: "me", votes: [], voter: "anon:bb")
        }
        let all = try await votes(db, seq: 1)
        XCTAssertEqual(all, ["anon:aa": [1]])
        XCTAssertFalse(all.keys.contains("peer") || all.keys.contains("me"),
                       "an anonymous poll never keys a vote by who sent it")
    }

    func testNamedPollIgnoresAPseudonym() async throws {
        let db = try AppDatabase.openInMemory()
        try await insertPoll(db, seq: 1, anonymous: false)
        try await db.write { dbc in
            try SyncEngine.applyPollVote(dbc, chatId: "c1", targetSeq: 1,
                                         userId: "peer", votes: [0], voter: "anon:aa")
        }
        let all = try await votes(db, seq: 1)
        XCTAssertEqual(all, ["peer": [0]], "a poll that asked for names gets them")
    }

    func testAnonymousVoteBeforeItsPollKeepsThePseudonym() async throws {
        let db = try AppDatabase.openInMemory()
        var event = ContentPayload(kind: "pollVote")
        event.targetSeq = 5
        event.votes = [1]
        event.voter = "anon:aa"
        try await db.write { dbc in
            try SyncEngine.bufferPendingApply(dbc, chatId: "c1", targetSeq: 5, kind: "pollVote",
                                              fromUserId: "peer",
                                              payload: SyncEngine.payloadJSON(event), seq: 6)
        }
        try await insertPoll(db, seq: 5, anonymous: true)
        try await db.write { dbc in try SyncEngine.applyBuffered(dbc, chatId: "c1", seq: 5) }
        let all = try await votes(db, seq: 5)
        XCTAssertEqual(all, ["anon:aa": [1]])
    }

    func testPseudonymIsOnePerAccountPerPoll() {
        let alice = IdentityKeyPair()
        let bob = IdentityKeyPair()
        let a1 = PollPseudonym.make(identity: alice, pollId: "poll-1")
        XCTAssertEqual(a1, PollPseudonym.make(identity: alice, pollId: "poll-1"),
                       "every device of the account derives the same key")
        XCTAssertNotEqual(a1, PollPseudonym.make(identity: alice, pollId: "poll-2"),
                          "two polls cannot be joined on a voter")
        XCTAssertNotEqual(a1, PollPseudonym.make(identity: bob, pollId: "poll-1"))
        XCTAssertTrue(a1.hasPrefix(PollPseudonym.prefix))

        let named = PollInfo(id: "poll-1", question: "?", options: ["a", "b"], multiple: false, anonymous: false)
        var anonymous = named
        anonymous.anonymous = true
        XCTAssertEqual(PollPseudonym.voterKey(poll: named, ownUserId: "u1", identity: alice), "u1")
        XCTAssertEqual(PollPseudonym.voterKey(poll: anonymous, ownUserId: "u1", identity: alice), a1)
        anonymous.id = nil
        XCTAssertEqual(PollPseudonym.voterKey(poll: anonymous, ownUserId: "u1", identity: alice), "u1",
                       "with nothing to derive from, the vote falls back to the name")
    }

    private func votes(_ db: DatabaseQueue, seq: Int) async throws -> [String: [Int]] {
        try await db.read { dbc in
            try Message.fetchOne(dbc, key: "p\(seq)")?.pollVotes ?? [:]
        }
    }

    func testPollRoundTripsThroughTheDatabase() async throws {
        let db = try AppDatabase.openInMemory()
        try await insertPoll(db, seq: 1)
        let stored = try await db.read { dbc in try Message.fetchOne(dbc, key: "p1") }
        XCTAssertEqual(stored?.poll?.question, "Lunch?")
        XCTAssertEqual(stored?.poll?.options, ["Pizza", "Sushi", "Soup"])
        XCTAssertEqual(stored?.poll?.multiple, false)
    }

    func testVoteReplacesAndRetracts() async throws {
        let db = try AppDatabase.openInMemory()
        try await insertPoll(db, seq: 1)
        try await db.write { dbc in
            XCTAssertTrue(try SyncEngine.applyPollVote(dbc, chatId: "c1", targetSeq: 1,
                                                       userId: "peer", votes: [0]))
            XCTAssertTrue(try SyncEngine.applyPollVote(dbc, chatId: "c1", targetSeq: 1,
                                                       userId: "me", votes: [2, 1]))
        }
        var all = try await votes(db, seq: 1)
        XCTAssertEqual(all["peer"], [0])
        XCTAssertEqual(all["me"], [1, 2], "choices are stored sorted")

        try await db.write { dbc in
            // a new choice replaces the old one whole; an empty one retracts
            try SyncEngine.applyPollVote(dbc, chatId: "c1", targetSeq: 1, userId: "peer", votes: [1])
            try SyncEngine.applyPollVote(dbc, chatId: "c1", targetSeq: 1, userId: "me", votes: [])
        }
        all = try await votes(db, seq: 1)
        XCTAssertEqual(all["peer"], [1])
        XCTAssertNil(all["me"])
    }

    func testVoteBeforeItsPollWaitsAndLands() async throws {
        let db = try AppDatabase.openInMemory()
        var event = ContentPayload(kind: "pollVote")
        event.targetSeq = 5
        event.votes = [1]
        try await db.write { dbc in
            XCTAssertFalse(try SyncEngine.applyPollVote(dbc, chatId: "c1", targetSeq: 5,
                                                        userId: "peer", votes: [1]))
            try SyncEngine.bufferPendingApply(dbc, chatId: "c1", targetSeq: 5, kind: "pollVote",
                                              fromUserId: "peer",
                                              payload: SyncEngine.payloadJSON(event), seq: 6)
        }
        try await insertPoll(db, seq: 5)
        try await db.write { dbc in
            try SyncEngine.applyBuffered(dbc, chatId: "c1", seq: 5)
        }
        let all = try await votes(db, seq: 5)
        XCTAssertEqual(all["peer"], [1])
    }

    func testPollVoteIsAServiceKindAndPollIsNot() {
        XCTAssertTrue(SyncEngine.serviceKinds.contains("pollVote"))
        XCTAssertTrue(SyncEngine.rowlessKinds.contains("pollVote"))
        XCTAssertTrue(NotificationContentBuilder.silentKinds.contains("pollVote"))
        XCTAssertFalse(SyncEngine.serviceKinds.contains("poll"),
                       "the poll itself is content: it grows unread and raises a push")
    }

    func testPollPushPreviewCarriesTheQuestion() {
        var payload = ContentPayload(kind: "poll")
        payload.poll = PollInfo(question: "Lunch?", options: ["A", "B"],
                                multiple: false, anonymous: true)
        let preview = NotificationContentBuilder.preview(payload)
        XCTAssertTrue(preview.contains("Lunch?"))
    }
}
