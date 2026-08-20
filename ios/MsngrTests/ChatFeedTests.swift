import XCTest
@testable import Msngr
import MsngrCore

/// What buildFeed puts on screen: unique item ids, the unread marker, series
/// grouping and reply authors. The feed is ordered by seq, and sentAt along it
/// may go backwards, so two date separators can carry the same label.
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
        // the feed runs by seq DESC while sentAt jumps: day A, day B, day A again
        let msgs = [
            msg("m3", sentAt: base, seq: 3),
            msg("m2", sentAt: base + 2 * day, seq: 2),
            msg("m1", sentAt: base + day / 2, seq: 1),
        ]
        let feed = ChatViewModel.buildFeed(msgs, members: [])

        let ids = feed.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "feed item ids must be unique: \(ids)")

        // the same day appears twice: two separators, one label
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

    // The unread marker: in the inverted feed it follows the oldest message
    // with seq >= the anchor, which on screen puts it above the first unread one.
    @MainActor
    func testUnreadMarkerAboveFirstUnread() {
        let base: TimeInterval = 1_700_000_000
        let msgs = [
            incoming("m5", sentAt: base + 40, seq: 5),
            incoming("m4", sentAt: base + 30, seq: 4),
            incoming("m3", sentAt: base + 20, seq: 3),  // first unread
            msg("m2", sentAt: base + 10, seq: 2),
            msg("m1", sentAt: base, seq: 1),
        ]
        let feed = ChatViewModel.buildFeed(msgs, members: [],
                                           unreadMarker: (anchorSeq: 3, count: 3))
        let markerIdx = feed.firstIndex { if case .unreadMarker = $0 { return true }; return false }
        XCTAssertNotNil(markerIdx)
        // the item just before the marker in the array is m3, which on screen sits under it
        if case .message(let m, _, _, _, _, _, _) = feed[markerIdx! - 1] {
            XCTAssertEqual(m.id, "m3")
        } else {
            XCTFail("the first unread message must precede the marker, got \(feed[markerIdx! - 1])")
        }
        if case .unreadMarker(let id, let count) = feed[markerIdx!] {
            XCTAssertEqual(id, "unread:3", "the id is stable and tied to the anchor seq")
            XCTAssertEqual(count, 3)
        }
        XCTAssertEqual(feed.map(\.id).count, Set(feed.map(\.id)).count)
    }

    // the count grows while the anchor holds, so the marker id stays the same
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

    // without the marker parameter the feed carries no marker
    @MainActor
    func testNoMarkerWithoutParam() {
        let base: TimeInterval = 1_700_000_000
        let feed = ChatViewModel.buildFeed([incoming("m1", sentAt: base, seq: 1)], members: [])
        XCTAssertFalse(feed.contains { if case .unreadMarker = $0 { return true }; return false })
    }

    /// A request before it is accepted shows an empty feed: what the database
    /// holds never reaches the screen. Once accepted the same history builds
    /// as usual.
    @MainActor
    func testFeedHiddenForRequestChat() {
        let base: TimeInterval = 1_700_000_000
        let msgs = [incoming("m3", sentAt: base + 20, seq: 3),
                    incoming("m2", sentAt: base + 10, seq: 2),
                    incoming("m1", sentAt: base, seq: 1)]
        XCTAssertTrue(ChatViewModel.buildFeed(msgs, members: [], contentHidden: true).isEmpty)
        let shown = ChatViewModel.buildFeed(msgs, members: [], contentHidden: false)
        XCTAssertEqual(shown.compactMap { item -> String? in
            if case .message(let m, _, _, _, _, _, _) = item { return m.id }
            return nil
        }, ["m3", "m2", "m1"])
    }

    // MARK: - Series grouping: tail and gap

    /// Grouping flags in feed order, index 0 being the newest message.
    private func grouping(_ feed: [ChatFeedItem]) -> [(id: String, tightGap: Bool, showTail: Bool)] {
        feed.compactMap { item in
            if case .message(let m, let tightGap, let showTail, _, _, _, _) = item {
                return (m.id, tightGap, showTail)
            }
            return nil
        }
    }

    /// One author within a minute: only the bottom bubble gets a tail, the
    /// rest get the tight gap above them.
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
                       "only the newest message of a series carries the tail")
        // continuations get the tight gap; the oldest one opens the series
        XCTAssertEqual(g.map(\.tightGap), [true, true, false])
    }

    /// A pause over a minute breaks the series: both get a tail and a normal gap.
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

    /// Exactly 60 seconds is already too far apart: the condition is < 60.
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

    /// Alternating authors: every message stands as its own series.
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

    /// A day change breaks a run by the same author even when the two messages
    /// are less than a minute apart.
    @MainActor
    func testDayChangeBreaksSeries() {
        // 23:59:40 and 00:00:10 the next day: 30 seconds apart, different days
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
        XCTAssertEqual(g.map(\.showTail), [true, true], "a day change breaks the series")
        XCTAssertEqual(g.map(\.tightGap), [false, false])
    }

    /// A system message never joins a series with its author's neighbours.
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

    // MARK: - Reply author in the feed

    private func replyAuthorNames(_ feed: [ChatFeedItem]) -> [String?] {
        feed.compactMap { item in
            if case .message(_, _, _, _, _, let replyAuthorName, _) = item { return replyAuthorName }
            return nil
        }
    }

    /// Quoting your own message names you; quoting someone else names that
    /// member from `members`; a message without a quote has no name at all.
    @MainActor
    func testReplyAuthorNameResolvedFromMembers() {
        let base: TimeInterval = 1_700_000_000
        let alice = User(id: "me", username: "me", displayName: "Me")
        let bob = User(id: "peer", username: "bob", displayName: "Bob")
        var replyToOwn = msg("m2", sentAt: base + 10, seq: 2)
        replyToOwn.replyTo = ReplyPreview(msgId: "m1", authorId: "me", text: "mine", kind: "text")
        var replyToPeer = incoming("m3", sentAt: base + 20, seq: 3)
        replyToPeer.replyTo = ReplyPreview(msgId: "m1", authorId: "peer", text: "theirs", kind: "text")
        let plain = msg("m1", sentAt: base, seq: 1)

        let feed = ChatViewModel.buildFeed([replyToPeer, replyToOwn, plain],
                                           members: [alice, bob], ownId: "me")
        let names = feed.compactMap { item -> (String, String?)? in
            if case .message(let m, _, _, _, _, let name, _) = item { return (m.id, name) }
            return nil
        }
        func name(for id: String) -> String? { names.first { $0.0 == id }?.1 ?? nil }
        XCTAssertEqual(name(for: "m2"), "Вы")
        XCTAssertEqual(name(for: "m3"), "Bob")
        XCTAssertNil(name(for: "m1"), "no replyTo means no quote author")
    }

    /// The quoted author is not among the members any more (left the chat):
    /// the quote falls back to "?" instead of a raw userId or a crash.
    @MainActor
    func testReplyAuthorNameFallsBackForUnknownMember() {
        let base: TimeInterval = 1_700_000_000
        var m = msg("m2", sentAt: base + 10, seq: 2)
        m.replyTo = ReplyPreview(msgId: "m1", authorId: "left-the-chat", text: "some text", kind: "text")
        let feed = ChatViewModel.buildFeed([m], members: [], ownId: "me")
        XCTAssertEqual(replyAuthorNames(feed).first ?? nil, "?")
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
