import XCTest
@testable import Msngr
import MsngrCore

/// Уникальность id элементов ленты: дата-сепараторы с одинаковым label
/// не должны давать одинаковый id (лента строится по порядку seq,
/// sentAt при этом может быть немонотонным).
final class ChatFeedTests: XCTestCase {
    private let day: TimeInterval = 86_400

    private func msg(_ id: String, sentAt: TimeInterval, seq: Int) -> Message {
        var m = Message(id: id, chatId: "c", fromUserId: "me",
                        sentAt: sentAt, kind: .text, text: id,
                        status: .sent, isOutgoing: true)
        m.seq = seq
        return m
    }

    @MainActor
    func testSeparatorIdsUniqueForNonMonotonicSentAt() {
        let base: TimeInterval = 1_700_000_000
        // порядок ленты — по seq DESC; sentAt скачет: день A, день B, снова день A
        let msgs = [
            msg("m3", sentAt: base, seq: 3),
            msg("m2", sentAt: base + 2 * day, seq: 2),
            msg("m1", sentAt: base + day / 2, seq: 1),
        ]
        let feed = ChatViewModel.buildFeed(msgs, members: [])

        let ids = feed.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "id элементов ленты должны быть уникальны: \(ids)")

        // один и тот же день встречается дважды — сепаратора два, label одинаковый
        let separators = feed.compactMap { item -> (id: String, label: String)? in
            if case .dateSeparator(let id, let label) = item { return (id, label) }
            return nil
        }
        XCTAssertEqual(separators.count, 3)
        XCTAssertEqual(separators[0].label, separators[2].label)
        XCTAssertNotEqual(separators[0].id, separators[2].id)
    }

    @MainActor
    func testTwoMessagesSameDaySingleSeparator() {
        let base: TimeInterval = 1_700_000_000
        let msgs = [
            msg("m2", sentAt: base + 60, seq: 2),
            msg("m1", sentAt: base, seq: 1),
        ]
        let feed = ChatViewModel.buildFeed(msgs, members: [])
        let ids = feed.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        let separators = feed.filter { if case .dateSeparator = $0 { return true }; return false }
        XCTAssertEqual(separators.count, 1)
    }
}
