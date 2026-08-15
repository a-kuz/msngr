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
                msg.msgId = "m\(seq)"
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

        // окно у начала локальной истории: ниже брать нечего
        let atStart = try db.read { dbc -> (Bool, Int?) in
            (try HistoryWindow.hasOlder(dbc, chatId: "c1", floor: 1),
             try HistoryWindow.floorBelow(dbc, chatId: "c1", floor: 1, limit: 30))
        }
        XCTAssertFalse(atStart.0)
        XCTAssertNil(atStart.1)
    }

    /// Сообщения без seq (своё, до ack) всегда в самой новой странице.
    func testUnacknowledgedOwnMessageStaysInWindow() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, lastSeq: 10, syncedSeq: 10)
        try seedMessages(db, seqs: Array(1...10))
        try db.write { dbc in
            var msg = Message(id: "local", chatId: "c1", fromUserId: "me", sentAt: 99,
                              kind: .text, text: "не подтверждено", status: .sending, isOutgoing: true)
            msg.clientMsgId = "local"
            try msg.save(dbc)
        }
        let page = try db.read { dbc in try HistoryWindow.messages(dbc, chatId: "c1", floor: 9) }
        XCTAssertEqual(page.map(\.id), ["local", "m10", "m9"])
    }

    // MARK: - Seq gaps

    func testGapsBetweenAdjacentSeqs() {
        XCTAssertEqual(HistoryWindow.gaps(known: [1, 2, 5, 6, 10], lower: 1, upper: 10),
                       [3...4, 7...9])
        XCTAssertEqual(HistoryWindow.gaps(known: [], lower: 4, upper: 6), [4...6])
        XCTAssertEqual(HistoryWindow.gaps(known: [1, 2, 3], lower: 1, upper: 3), [])
        XCTAssertEqual(HistoryWindow.gaps(known: [7], lower: 10, upper: 12), [10...12])
    }

    /// Ниже курсора синхронизации дыр нет по построению: syncedSeq двигается
    /// только по непрерывному префиксу.
    func testGapsLiveAboveSyncCursorOnly() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, lastSeq: 20, syncedSeq: 10)
        try seedMessages(db, seqs: [1, 2, 3, 11, 15, 20])
        let gaps = try db.read { dbc in try HistoryWindow.openGaps(dbc, chatId: "c1") }
        XCTAssertEqual(gaps, [12...14, 16...19])
    }

    /// Служебный фрейм (реакция, правка) занимает seq и строки в ленте не даёт —
    /// после его применения дыра закрыта записью, а не сообщением.
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

    /// Тот же разрыв не уходит на сервер бесконечно: зафиксированный нечитаемый
    /// seq закрывает диапазон, повторный проход его уже не видит.
    func testRecordedUnreadableSeqIsNotRequestedAgain() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, lastSeq: 6, syncedSeq: 3)
        try seedMessages(db, seqs: [1, 2, 3, 6])
        let before = try db.read { dbc in try HistoryWindow.openGaps(dbc, chatId: "c1") }
        XCTAssertEqual(before, [4...5])

        try db.write { dbc in
            for seq in 4...5 {
                try HistoryWindow.recordGap(dbc, chatId: "c1", seq: seq, reason: "bad_box",
                                            msgId: "srv\(seq)", fromUserId: "peer", sentAt: Double(seq))
            }
        }
        let after = try db.read { dbc in try HistoryWindow.openGaps(dbc, chatId: "c1") }
        XCTAssertTrue(after.isEmpty)

        // причина и счётчик попыток остаются в базе — ремонт опирается на них
        let row = try db.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT * FROM historyGap WHERE chatId = 'c1' AND seq = 4")!
        }
        XCTAssertEqual(row["reason"] as String, "bad_box")
        XCTAssertEqual(row["attempts"] as Int, 1)
        XCTAssertEqual(row["fromUserId"] as String?, "peer")
    }

    /// Заглушка в ленте — терминальное состояние: пока попытки не исчерпаны,
    /// нечитаемый seq в ленту не выходит.
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

    /// Конверт, адресованный другому устройству, и служебный фрейм заглушки не
    /// получают ни при каком числе попыток.
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

    /// Заглушки ниже окна в ленту не идут: окно расширяется — они появляются.
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
}
