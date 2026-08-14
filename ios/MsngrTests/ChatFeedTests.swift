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

    private func incoming(_ id: String, sentAt: TimeInterval, seq: Int) -> Message {
        var m = Message(id: id, chatId: "c", fromUserId: "peer",
                        sentAt: sentAt, kind: .text, text: id,
                        status: .sent, isOutgoing: false)
        m.seq = seq
        return m
    }

    // Плашка непрочитанных: в инвертированной ленте стоит сразу после самого
    // старого сообщения с seq >= якоря (на экране — над первым непрочитанным).
    @MainActor
    func testUnreadMarkerAboveFirstUnread() {
        let base: TimeInterval = 1_700_000_000
        let msgs = [
            incoming("m5", sentAt: base + 40, seq: 5),
            incoming("m4", sentAt: base + 30, seq: 4),
            incoming("m3", sentAt: base + 20, seq: 3),  // первый непрочитанный
            msg("m2", sentAt: base + 10, seq: 2),
            msg("m1", sentAt: base, seq: 1),
        ]
        let feed = ChatViewModel.buildFeed(msgs, members: [],
                                           unreadMarker: (anchorSeq: 3, count: 3))
        let markerIdx = feed.firstIndex { if case .unreadMarker = $0 { return true }; return false }
        XCTAssertNotNil(markerIdx)
        // элемент прямо перед маркером в массиве — сообщение m3 (на экране оно под плашкой)
        if case .message(let m, _, _, _, _) = feed[markerIdx! - 1] {
            XCTAssertEqual(m.id, "m3")
        } else {
            XCTFail("перед маркером должно быть первое непрочитанное, есть \(feed[markerIdx! - 1])")
        }
        if case .unreadMarker(let id, let count) = feed[markerIdx!] {
            XCTAssertEqual(id, "unread:3", "id стабилен и привязан к якорному seq")
            XCTAssertEqual(count, 3)
        }
        XCTAssertEqual(feed.map(\.id).count, Set(feed.map(\.id)).count)
    }

    // счётчик растёт, якорь тот же — id маркера не меняется
    @MainActor
    func testUnreadMarkerIdStableWhenCountGrows() {
        let base: TimeInterval = 1_700_000_000
        let msgs = [incoming("m2", sentAt: base + 10, seq: 2),
                    msg("m1", sentAt: base, seq: 1)]
        let feed1 = ChatViewModel.buildFeed(msgs, members: [], unreadMarker: (anchorSeq: 2, count: 1))
        let more = [incoming("m3", sentAt: base + 20, seq: 3)] + msgs
        let feed2 = ChatViewModel.buildFeed(more, members: [], unreadMarker: (anchorSeq: 2, count: 2))
        let id1 = feed1.compactMap { i -> String? in
            if case .unreadMarker(let id, _) = i { return id }; return nil
        }.first
        let id2 = feed2.compactMap { i -> String? in
            if case .unreadMarker(let id, _) = i { return id }; return nil
        }.first
        XCTAssertNotNil(id1)
        XCTAssertEqual(id1, id2)
    }

    // без параметра маркера лента не содержит плашку
    @MainActor
    func testNoMarkerWithoutParam() {
        let base: TimeInterval = 1_700_000_000
        let feed = ChatViewModel.buildFeed([incoming("m1", sentAt: base, seq: 1)], members: [])
        XCTAssertFalse(feed.contains { if case .unreadMarker = $0 { return true }; return false })
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
