import XCTest
@testable import MsngrCore

/// The trace of the extension: how many pushes the system let it service is
/// countable only from what the extension itself wrote down.
final class NotificationJournalTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-\(UUID().uuidString).log")
    }

    func testRecordsEveryPhaseOfAPush() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = NotificationJournal(url: url)

        journal.record(.received, msgId: "m1", seq: 7, at: 100)
        journal.record(.answered, msgId: "m1", seq: 7, detail: "show", at: 101.5)
        journal.record(.expired, msgId: "m2", seq: 8, at: 130)

        let entries = journal.entries()
        XCTAssertEqual(entries.map(\.phase), [.received, .answered, .expired])
        XCTAssertEqual(entries[0].msgId, "m1")
        XCTAssertEqual(entries[0].seq, 7)
        XCTAssertEqual(entries[1].detail, "show")
        XCTAssertEqual(entries[2].at, 130, accuracy: 0.001)
    }

    /// Counting a burst: how many of the pushes handed over actually entered
    /// the extension.
    func testCountsInvocationsOfABurst() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = NotificationJournal(url: url)
        for seq in 1...25 {
            journal.record(.received, msgId: "m\(seq)", seq: seq, at: Double(seq))
        }
        XCTAssertEqual(journal.entries().filter { $0.phase == .received }.count, 25)
    }

    /// The extension has no room for a growing file: the oldest half goes, the
    /// newest entries stay readable.
    func testTrimsToTheNewestEntries() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = NotificationJournal(url: url, limit: 2048)
        for seq in 1...500 {
            journal.record(.received, msgId: "message-\(seq)", seq: seq, at: Double(seq))
        }
        let entries = journal.entries()
        XCTAssertFalse(entries.isEmpty)
        XCTAssertLessThan(entries.count, 500)
        XCTAssertEqual(entries.last?.seq, 500)
        // no half-written first line survives the cut
        XCTAssertTrue(entries.allSatisfy { $0.msgId.hasPrefix("message-") })
    }

    func testMalformedLinesAreIgnored() {
        let entries = NotificationJournal.parse("""
            100.000\treceived\tm1\t1\t
            garbage
            \t\t\t
            101.000\tanswered\tm1\t1\tshow
            """)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.last?.detail, "show")
    }
}
