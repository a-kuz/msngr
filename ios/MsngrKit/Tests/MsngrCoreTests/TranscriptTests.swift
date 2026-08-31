import XCTest
import GRDB
@testable import MsngrCore

/// A voice transcript is local: the text, its word timings and the unfolded
/// flag live on the message row, and the playback highlight interpolates
/// inside the word being spoken.
final class TranscriptTests: XCTestCase {
    func testTranscriptRoundTripsThroughTheDatabase() async throws {
        let db = try AppDatabase.openInMemory()
        try await db.write { dbc in
            var msg = Message(id: "v1", chatId: "c1", fromUserId: "peer",
                              sentAt: 100, kind: .voice, text: nil, status: .sent,
                              isOutgoing: false)
            msg.transcript = "ну привет"
            msg.transcriptSpans = [TranscriptSpan(text: "ну ", start: 0, end: 0.4),
                                   TranscriptSpan(text: "привет", start: 0.4, end: 1.0)]
            msg.transcriptShown = true
            try msg.save(dbc)
        }
        let stored = try await db.read { dbc in try Message.fetchOne(dbc, key: "v1") }
        XCTAssertEqual(stored?.transcript, "ну привет")
        XCTAssertEqual(stored?.transcriptSpans.count, 2)
        XCTAssertEqual(stored?.transcriptSpans.last?.text, "привет")
        XCTAssertEqual(stored?.transcriptSpans.last?.end, 1.0)
        XCTAssertEqual(stored?.transcriptShown, true)
    }

    func testAMessageWithoutATranscriptReadsBackEmpty() async throws {
        let db = try AppDatabase.openInMemory()
        try await db.write { dbc in
            try Message(id: "v2", chatId: "c1", fromUserId: "peer",
                        sentAt: 100, kind: .voice, text: nil, status: .sent,
                        isOutgoing: false).save(dbc)
        }
        let stored = try await db.read { dbc in try Message.fetchOne(dbc, key: "v2") }
        XCTAssertNil(stored?.transcript)
        XCTAssertEqual(stored?.transcriptSpans, [])
        XCTAssertEqual(stored?.transcriptShown, false)
    }

    func testSpokenLengthInterpolatesInsideTheCurrentWord() {
        let spans = [TranscriptSpan(text: "one ", start: 0, end: 1),   // 4 units
                     TranscriptSpan(text: "two", start: 1, end: 2)]    // 3 units
        XCTAssertEqual(TranscriptSpan.spokenLength(spans, at: 0), 0)
        XCTAssertEqual(TranscriptSpan.spokenLength(spans, at: 0.5), 2, "halfway through the first word")
        XCTAssertEqual(TranscriptSpan.spokenLength(spans, at: 1), 4, "the first word is done")
        XCTAssertEqual(TranscriptSpan.spokenLength(spans, at: 1.5), 6, "one and a half units into the second")
        XCTAssertEqual(TranscriptSpan.spokenLength(spans, at: 5), 7, "past the end everything is spoken")
    }

    func testSpokenLengthCountsUTF16Units() {
        // an emoji is 2 UTF-16 units: the boundary must match NSRange arithmetic
        let spans = [TranscriptSpan(text: "🙂🙂", start: 0, end: 1)]
        XCTAssertEqual(TranscriptSpan.spokenLength(spans, at: 2), 4)
    }
}
