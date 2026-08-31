import XCTest
import GRDB
@testable import MsngrCore

/// Upward pagination: the window grows over the local database, and the server
/// is asked only for seq ranges this device has never processed.
final class HistoryWindowTests: XCTestCase {
    private func seedChat(_ db: DatabaseQueue, id: String = "c1",
                          lastSeq: Int, syncedSeq: Int) throws {
        var chat = Chat(id: id, kind: .direct, title: nil, createdBy: "peer", createdAt: 0,
                        lastSeq: lastSeq, syncedSeq: syncedSeq, lastActivityAt: 0)
        chat.myReadUpTo = 0
        try db.write { dbc in try chat.save(dbc) }
    }

    private func seedMessages(_ db: DatabaseQueue, chatId: String = "c1", seqs: [Int]) throws {
        try db.write { dbc in
            for seq in seqs {
                var msg = Message(id: "m\(seq)", chatId: chatId, fromUserId: "peer",
                                  sentAt: Double(seq), kind: .text, text: "msg \(seq)",
                                  status: .sent, isOutgoing: false)
                msg.seq = seq
                try msg.save(dbc)
            }
        }
    }

    // MARK: - Window over the local database

    /// The first page holds the newest messages; each expansion brings the next
    /// portion from the local database, down to the oldest one stored.
    func testWindowGrowsDownwardsOverLocalDatabase() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, lastSeq: 100, syncedSeq: 100)
        try seedMessages(db, seqs: Array(1...100))

        let (firstFloor, firstPage) = try db.read { dbc -> (Int?, [Message]) in
            let floor = try HistoryWindow.newestFloor(dbc, chatId: "c1", limit: 30)
            return (floor, try HistoryWindow.messages(dbc, chatId: "c1", floor: floor))
        }
        XCTAssertEqual(firstFloor, 71)
        XCTAssertEqual(firstPage.count, 30)
        XCTAssertEqual(firstPage.first?.seq, 100)
        XCTAssertEqual(firstPage.last?.seq, 71)

        let (secondFloor, secondPage) = try db.read { dbc -> (Int?, [Message]) in
            let floor = try HistoryWindow.floorBelow(dbc, chatId: "c1", floor: 71, limit: 30)
            return (floor, try HistoryWindow.messages(dbc, chatId: "c1", floor: floor))
        }
        XCTAssertEqual(secondFloor, 41)
        XCTAssertEqual(secondPage.count, 60)
        XCTAssertEqual(secondPage.last?.seq, 41)

        // the window sits at the start of local history: there is nothing below it
        let atStart = try db.read { dbc -> (Bool, Int?) in
            (try HistoryWindow.hasOlder(dbc, chatId: "c1", floor: 1),
             try HistoryWindow.floorBelow(dbc, chatId: "c1", floor: 1, limit: 30))
        }
        XCTAssertFalse(atStart.0)
        XCTAssertNil(atStart.1)
    }

    /// A message with no seq yet, our own before the ack, always belongs to the newest page.
    func testUnacknowledgedOwnMessageStaysInWindow() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, lastSeq: 10, syncedSeq: 10)
        try seedMessages(db, seqs: Array(1...10))
        try db.write { dbc in
            var msg = Message(id: "local", chatId: "c1", fromUserId: "me", sentAt: 99,
                              kind: .text, text: "not acknowledged", status: .sending, isOutgoing: true)
            msg.clientMsgId = "local"
            try msg.save(dbc)
        }
        let page = try db.read { dbc in try HistoryWindow.messages(dbc, chatId: "c1", floor: 9) }
        XCTAssertEqual(page.map(\.id), ["local", "m10", "m9"])
    }

    // MARK: - Seq gaps

    /// Whether the window was cut short of the end of the chat: what tells a feed
    /// standing on a jump target from one standing at the newest message.
    func testKnowsWhetherAnythingIsNewerThanTheWindow() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, lastSeq: 100, syncedSeq: 100)
        try seedMessages(db, seqs: Array(1...100))
        try db.read { dbc in
            XCTAssertTrue(try HistoryWindow.hasNewer(dbc, chatId: "c1", topSeq: 60))
            XCTAssertFalse(try HistoryWindow.hasNewer(dbc, chatId: "c1", topSeq: 100))
            // an own message still waiting for its seq sorts above everything numbered
            XCTAssertFalse(try HistoryWindow.hasNewer(dbc, chatId: "c1", topSeq: nil))
        }
    }

    func testGapsBetweenAdjacentSeqs() {
        XCTAssertEqual(HistoryWindow.gaps(known: [1, 2, 5, 6, 10], lower: 1, upper: 10),
                       [3...4, 7...9])
        XCTAssertEqual(HistoryWindow.gaps(known: [], lower: 4, upper: 6), [4...6])
        XCTAssertEqual(HistoryWindow.gaps(known: [1, 2, 3], lower: 1, upper: 3), [])
        XCTAssertEqual(HistoryWindow.gaps(known: [7], lower: 10, upper: 12), [10...12])
    }

    /// Below the sync cursor there are no gaps by construction: syncedSeq only
    /// moves along the contiguous prefix.
    func testGapsLiveAboveSyncCursorOnly() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, lastSeq: 20, syncedSeq: 10)
        try seedMessages(db, seqs: [1, 2, 3, 11, 15, 20])
        let gaps = try db.read { dbc in try HistoryWindow.openGaps(dbc, chatId: "c1") }
        XCTAssertEqual(gaps, [12...14, 16...19])
    }

    /// A service frame such as a reaction or an edit takes a seq without adding a
    /// feed row, so once it is applied the gap is closed by a record rather than
    /// by a message.
    func testAppliedServiceFrameClosesItsSeq() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, lastSeq: 5, syncedSeq: 2)
        try seedMessages(db, seqs: [1, 2, 3, 5])
        try db.write { dbc in
            try HistoryWindow.recordGap(dbc, chatId: "c1", seq: 4, reason: "service")
        }
        let gaps = try db.read { dbc in try HistoryWindow.openGaps(dbc, chatId: "c1") }
        XCTAssertTrue(gaps.isEmpty)
    }

    /// The same gap does not go back to the server forever: recording a seq as
    /// unreadable closes the range, and the next pass no longer sees it.
    func testRecordedUnreadableSeqIsNotRequestedAgain() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, lastSeq: 6, syncedSeq: 3)
        try seedMessages(db, seqs: [1, 2, 3, 6])
        let before = try db.read { dbc in try HistoryWindow.openGaps(dbc, chatId: "c1") }
        XCTAssertEqual(before, [4...5])

        try db.write { dbc in
            for seq in 4...5 {
                try HistoryWindow.recordGap(dbc, chatId: "c1", seq: seq, reason: "bad_box",
                                            fromUserId: "peer", sentAt: Double(seq))
            }
        }
        let after = try db.read { dbc in try HistoryWindow.openGaps(dbc, chatId: "c1") }
        XCTAssertTrue(after.isEmpty)

        // the reason and the attempt counter stay in the database: repair works off them
        let row = try db.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT * FROM historyGap WHERE chatId = 'c1' AND seq = 4")!
        }
        XCTAssertEqual(row["reason"] as String, "bad_box")
        XCTAssertEqual(row["attempts"] as Int, 1)
        XCTAssertEqual(row["fromUserId"] as String?, "peer")
    }

    /// A placeholder in the feed is a terminal state: while attempts remain, an
    /// unreadable seq never reaches the feed.
    func testPlaceholderOnlyAfterAttemptsAreSpent() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, lastSeq: 6, syncedSeq: 6)
        try db.write { dbc in
            try HistoryWindow.recordGap(dbc, chatId: "c1", seq: 4, reason: "bad_box")
        }
        var shown = try db.read { dbc in try HistoryWindow.exhaustedGapSeqs(dbc, chatId: "c1", floor: nil) }
        XCTAssertTrue(shown.isEmpty)

        try db.write { dbc in
            for _ in 2...HistoryWindow.maxGapAttempts {
                try HistoryWindow.recordGap(dbc, chatId: "c1", seq: 4, reason: "bad_box")
            }
        }
        shown = try db.read { dbc in try HistoryWindow.exhaustedGapSeqs(dbc, chatId: "c1", floor: nil) }
        XCTAssertEqual(shown, [4])
    }

    /// An envelope addressed to another device, and a service frame, get no
    /// placeholder however many attempts are spent on them.
    func testSilentReasonsNeverReachTheFeed() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, lastSeq: 9, syncedSeq: 9)
        try db.write { dbc in
            for reason in HistoryWindow.silentGapReasons.sorted().enumerated() {
                for _ in 1...(HistoryWindow.maxGapAttempts + 1) {
                    try HistoryWindow.recordGap(dbc, chatId: "c1", seq: reason.offset + 1,
                                                reason: reason.element)
                }
            }
        }
        let shown = try db.read { dbc in try HistoryWindow.exhaustedGapSeqs(dbc, chatId: "c1", floor: nil) }
        XCTAssertTrue(shown.isEmpty)
    }

    /// Placeholders below the window stay out of the feed and appear once the window grows.
    func testExhaustedSeqsAreLimitedToTheWindow() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, lastSeq: 30, syncedSeq: 30)
        try db.write { dbc in
            for seq in [5, 25] {
                for _ in 1...HistoryWindow.maxGapAttempts {
                    try HistoryWindow.recordGap(dbc, chatId: "c1", seq: seq, reason: "bad_mac")
                }
            }
        }
        let inWindow = try db.read { dbc in try HistoryWindow.exhaustedGapSeqs(dbc, chatId: "c1", floor: 20) }
        XCTAssertEqual(inWindow, [25])
        let wider = try db.read { dbc in try HistoryWindow.exhaustedGapSeqs(dbc, chatId: "c1", floor: 1) }
        XCTAssertEqual(wider, [5, 25])
    }

    // MARK: - Chat row preview

    /// A backfilled message never replaces the row's preview with an older
    /// seq, even when its server timestamp is not behind the message already
    /// shown.
    func testLastMessageHoldsTheHighestSeqRegardlessOfTimestamp() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, lastSeq: 10, syncedSeq: 0)
        try db.write { dbc in
            // the freshest message lands first, as it does right after an
            // install, before the older history has been backfilled
            var latest = Message(id: "m10", chatId: "c1", fromUserId: "peer",
                                 sentAt: 100, kind: .text, text: "latest",
                                 status: .sent, isOutgoing: false)
            latest.seq = 10
            latest.serverTs = 100
            try latest.save(dbc)
        }
        XCTAssertEqual(try db.read { try HistoryWindow.lastMessage($0, chatId: "c1")?.seq }, 10)

        try db.write { dbc in
            // the backfill writes an older seq whose server timestamp is not
            // behind the one already shown (clock skew between senders, or a
            // coarse timestamp shared by messages seeded together)
            var older = Message(id: "m5", chatId: "c1", fromUserId: "peer",
                                sentAt: 50, kind: .text, text: "older",
                                status: .sent, isOutgoing: false)
            older.seq = 5
            older.serverTs = 150
            try older.save(dbc)
        }
        XCTAssertEqual(try db.read { try HistoryWindow.lastMessage($0, chatId: "c1")?.seq }, 10)
    }

    /// An own send still queued (no seq yet) previews as the newest thing in
    /// the chat, above every seq the server has numbered.
    func testLastMessagePrefersAnUnsentSendOverNumberedHistory() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, lastSeq: 10, syncedSeq: 10)
        try seedMessages(db, seqs: Array(1...10))
        try db.write { dbc in
            var pending = Message(id: "pending", chatId: "c1", fromUserId: "me",
                                  sentAt: 1000, kind: .text, text: "sending…",
                                  status: .sending, isOutgoing: true)
            pending.seq = nil
            try pending.save(dbc)
        }
        XCTAssertEqual(try db.read { try HistoryWindow.lastMessage($0, chatId: "c1")?.id }, "pending")
    }
}
