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

    /// Заявка до принятия: лента пустая, сообщения из БД на экран не попадают.
    /// После принятия та же история строится обычным образом.
    @MainActor
    func testFeedHiddenForRequestChat() {
        let base: TimeInterval = 1_700_000_000
        let msgs = [incoming("m3", sentAt: base + 20, seq: 3),
                    incoming("m2", sentAt: base + 10, seq: 2),
                    incoming("m1", sentAt: base, seq: 1)]
        XCTAssertTrue(ChatViewModel.buildFeed(msgs, members: [], contentHidden: true).isEmpty)
        let shown = ChatViewModel.buildFeed(msgs, members: [], contentHidden: false)
        XCTAssertEqual(shown.compactMap { item -> String? in
            if case .message(let m, _, _, _, _) = item { return m.id }
            return nil
        }, ["m3", "m2", "m1"])
    }

    // MARK: - Группировка серий: хвостик и зазор

    /// Флаги группировки сообщений ленты в её порядке (index 0 — самое новое).
    private func grouping(_ feed: [ChatFeedItem]) -> [(id: String, tightGap: Bool, showTail: Bool)] {
        feed.compactMap { item in
            if case .message(let m, let tightGap, let showTail, _, _) = item {
                return (m.id, tightGap, showTail)
            }
            return nil
        }
    }

    /// Серия одного автора внутри минуты: хвостик только у последнего снизу,
    /// у остальных тесный зазор сверху.
    @MainActor
    func testSeriesWithinMinuteTailOnlyOnNewest() {
        let base: TimeInterval = 1_700_000_000
        let msgs = [
            msg("m3", sentAt: base + 40, seq: 3),
            msg("m2", sentAt: base + 20, seq: 2),
            msg("m1", sentAt: base, seq: 1),
        ]
        let g = grouping(ChatViewModel.buildFeed(msgs, members: []))
        XCTAssertEqual(g.map(\.id), ["m3", "m2", "m1"])
        XCTAssertEqual(g.map(\.showTail), [true, false, false],
                       "хвостик только у самого нового сообщения серии")
        // тесный зазор — у продолжений серии; самое старое открывает серию
        XCTAssertEqual(g.map(\.tightGap), [true, true, false])
    }

    /// Разрыв больше минуты рвёт серию: хвостик у обоих, зазор обычный.
    @MainActor
    func testPauseOverMinuteBreaksSeries() {
        let base: TimeInterval = 1_700_000_000
        let msgs = [
            msg("m2", sentAt: base + 120, seq: 2),
            msg("m1", sentAt: base, seq: 1),
        ]
        let g = grouping(ChatViewModel.buildFeed(msgs, members: []))
        XCTAssertEqual(g.map(\.showTail), [true, true])
        XCTAssertEqual(g.map(\.tightGap), [false, false])
    }

    /// Ровно 60 секунд — уже не серия (условие строгое: < 60).
    @MainActor
    func testExactlySixtySecondsBreaksSeries() {
        let base: TimeInterval = 1_700_000_000
        let msgs = [
            msg("m2", sentAt: base + 60, seq: 2),
            msg("m1", sentAt: base, seq: 1),
        ]
        let g = grouping(ChatViewModel.buildFeed(msgs, members: []))
        XCTAssertEqual(g.map(\.showTail), [true, true])
    }

    /// Чередование авторов: каждое сообщение — своя серия.
    @MainActor
    func testAlternatingAuthorsBreakSeries() {
        let base: TimeInterval = 1_700_000_000
        let msgs = [
            msg("m4", sentAt: base + 30, seq: 4),
            incoming("m3", sentAt: base + 20, seq: 3),
            msg("m2", sentAt: base + 10, seq: 2),
            incoming("m1", sentAt: base, seq: 1),
        ]
        let g = grouping(ChatViewModel.buildFeed(msgs, members: []))
        XCTAssertEqual(g.map(\.showTail), [true, true, true, true])
        XCTAssertEqual(g.map(\.tightGap), [false, false, false, false])
    }

    /// Подряд идущие сообщения одного автора рвутся сменой дня,
    /// даже если по времени они укладываются в минуту.
    @MainActor
    func testDayChangeBreaksSeries() {
        // 23:59:40 и 00:00:10 следующего дня — разница 30 секунд, но дни разные
        var comps = DateComponents()
        comps.year = 2026; comps.month = 3; comps.day = 10
        comps.hour = 23; comps.minute = 59; comps.second = 40
        let cal = Calendar.current
        let late = cal.date(from: comps)!.timeIntervalSince1970
        let msgs = [
            msg("m2", sentAt: late + 30, seq: 2),
            msg("m1", sentAt: late, seq: 1),
        ]
        let g = grouping(ChatViewModel.buildFeed(msgs, members: []))
        XCTAssertEqual(g.map(\.showTail), [true, true], "смена дня рвёт серию")
        XCTAssertEqual(g.map(\.tightGap), [false, false])
    }

    /// Системное сообщение не склеивается в серию с соседями своего автора.
    @MainActor
    func testSystemMessageBreaksSeries() {
        let base: TimeInterval = 1_700_000_000
        var system = msg("s1", sentAt: base + 10, seq: 2)
        system.kind = .system
        let msgs = [
            msg("m2", sentAt: base + 20, seq: 3),
            system,
            msg("m1", sentAt: base, seq: 1),
        ]
        let g = grouping(ChatViewModel.buildFeed(msgs, members: []))
        XCTAssertEqual(g.map(\.showTail), [true, true, true])
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
