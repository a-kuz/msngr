import XCTest
@testable import Msngr
import MsngrCore

/// Sender avatars in group feeds and the floating day capsule: who carries the
/// picture in a run of messages, how the bubble makes room for it, and what the
/// sticky label shows at a day boundary.
final class FeedExtrasTests: XCTestCase {
    private let width: CGFloat = 390

    private func incoming(_ id: String, from user: String = "peer",
                          sentAt: TimeInterval, seq: Int) -> Message {
        var m = Message(id: id, chatId: "c", fromUserId: user,
                        sentAt: sentAt, kind: .text, text: id,
                        status: .sent, isOutgoing: false)
        m.seq = seq
        return m
    }

    private func outgoing(_ id: String, sentAt: TimeInterval, seq: Int) -> Message {
        var m = Message(id: id, chatId: "c", fromUserId: "me",
                        sentAt: sentAt, kind: .text, text: id,
                        status: .sent, isOutgoing: true)
        m.seq = seq
        return m
    }

    private let groupMembers = [
        User(id: "me", username: "me", displayName: "Me"),
        User(id: "peer", username: "peer", displayName: "Peer One", avatarId: "av-peer"),
        User(id: "third", username: "third", displayName: "Third"),
    ]

    private func feedAvatars(_ feed: [ChatFeedItem]) -> [(id: String, avatar: FeedAvatar?, showTail: Bool)] {
        feed.compactMap { item in
            if case .message(let m, _, let showTail, _, _, _, let avatar) = item {
                return (m.id, avatar, showTail)
            }
            return nil
        }
    }

    // MARK: - Who gets the avatar column

    /// In a group every incoming message of a run reserves the column, and the
    /// avatarId of the sender rides along; the picture itself lands with the
    /// tail, which the layout test below checks.
    @MainActor
    func testGroupIncomingRunAllReserveColumn() {
        let base: TimeInterval = 1_700_000_000
        let msgs = [
            incoming("m3", sentAt: base + 40, seq: 3),
            incoming("m2", sentAt: base + 20, seq: 2),
            incoming("m1", sentAt: base, seq: 1),
        ]
        let a = feedAvatars(ChatViewModel.buildFeed(msgs, members: groupMembers, ownId: "me"))
        XCTAssertEqual(a.map(\.showTail), [true, false, false])
        XCTAssertTrue(a.allSatisfy { $0.avatar != nil }, "the whole run leaves the space")
        XCTAssertEqual(a[0].avatar?.avatarId, "av-peer")
        XCTAssertEqual(a[0].avatar?.name, "Peer One")
    }

    /// Outgoing messages in a group carry no avatar: the bubble is on the right.
    @MainActor
    func testGroupOutgoingHasNoAvatar() {
        let base: TimeInterval = 1_700_000_000
        let feed = ChatViewModel.buildFeed([outgoing("m1", sentAt: base, seq: 1)],
                                           members: groupMembers, ownId: "me")
        XCTAssertNil(feedAvatars(feed).first?.avatar ?? nil)
    }

    /// A direct chat shows no avatars at all.
    @MainActor
    func testDirectChatHasNoAvatars() {
        let base: TimeInterval = 1_700_000_000
        let direct = [User(id: "me", username: "me", displayName: "Me"),
                      User(id: "peer", username: "peer", displayName: "Peer", avatarId: "av")]
        let feed = ChatViewModel.buildFeed([incoming("m1", sentAt: base, seq: 1)],
                                           members: direct, ownId: "me")
        XCTAssertNil(feedAvatars(feed).first?.avatar ?? nil)
    }

    /// A system line in a group is a note, not a bubble: no avatar column.
    @MainActor
    func testSystemMessageHasNoAvatar() {
        let base: TimeInterval = 1_700_000_000
        var system = incoming("s1", sentAt: base, seq: 1)
        system.kind = .system
        let feed = ChatViewModel.buildFeed([system], members: groupMembers, ownId: "me")
        XCTAssertNil(feedAvatars(feed).first?.avatar ?? nil)
    }

    // MARK: - The avatar in the layout plan

    /// The picture goes with the tail: the run's last message gets the frame,
    /// the continuations only keep the shifted bubble.
    func testPlanAvatarFrameFollowsTail() {
        let m = incoming("m1", sentAt: 1_700_000_000, seq: 1)
        let withTail = BubbleLayout.plan(for: m, width: width, tightGap: false, showTail: true,
                                         showName: false, authorName: "Peer", avatarInset: true)
        let noTail = BubbleLayout.plan(for: m, width: width, tightGap: true, showTail: false,
                                       showName: false, authorName: "Peer", avatarInset: true)
        XCTAssertNotNil(withTail.avatarFrame)
        XCTAssertNil(noTail.avatarFrame, "a continuation leaves the space empty")
        let af = withTail.avatarFrame!
        XCTAssertEqual(af.maxY, withTail.bubbleFrame.maxY, accuracy: 0.5,
                       "the picture is bottom-aligned with its bubble")
        XCTAssertLessThanOrEqual(af.maxX, withTail.bubbleFrame.minX,
                                 "the picture stays left of the bubble")
    }

    /// The column shifts and narrows an incoming group bubble; an outgoing one
    /// and a plain incoming one stay where they were.
    func testPlanAvatarInsetShiftsIncomingBubble() {
        let m = incoming("m1", sentAt: 1_700_000_000, seq: 1)
        let plain = BubbleLayout.plan(for: m, width: width, tightGap: false, showTail: true,
                                      showName: false, authorName: nil)
        let inset = BubbleLayout.plan(for: m, width: width, tightGap: false, showTail: true,
                                      showName: false, authorName: nil, avatarInset: true)
        XCTAssertEqual(inset.bubbleFrame.minX - plain.bubbleFrame.minX,
                       BubbleLayout.avatarSpan, accuracy: 0.5)

        let out = outgoing("m2", sentAt: 1_700_000_000, seq: 2)
        let outPlain = BubbleLayout.plan(for: out, width: width, tightGap: false, showTail: true,
                                         showName: false, authorName: nil)
        let outInset = BubbleLayout.plan(for: out, width: width, tightGap: false, showTail: true,
                                         showName: false, authorName: nil, avatarInset: true)
        XCTAssertEqual(outPlain.bubbleFrame, outInset.bubbleFrame,
                       "the column belongs to incoming bubbles only")
    }

    /// A wide bubble with the column keeps inside the screen: the maximum width
    /// gives the span up.
    func testPlanAvatarInsetNarrowsWideBubble() {
        var m = incoming("m1", sentAt: 1_700_000_000, seq: 1)
        // unbreakable text pushes both bubbles to their exact width caps
        m.text = String(repeating: "m", count: 400)
        let plain = BubbleLayout.plan(for: m, width: width, tightGap: false, showTail: true,
                                      showName: false, authorName: nil)
        let inset = BubbleLayout.plan(for: m, width: width, tightGap: false, showTail: true,
                                      showName: false, authorName: nil, avatarInset: true)
        XCTAssertLessThanOrEqual(inset.bubbleFrame.width,
                                 floor(width * Theme.bubbleMaxWidthRatio) - BubbleLayout.avatarSpan,
                                 "the width cap gives the avatar span up")
        XCTAssertLessThan(inset.bubbleFrame.width, plain.bubbleFrame.width)
        // shifted left edge plus narrowed width: the right edge stays inside the
        // boundary any bubble may use. Comparing against the plain plan's own
        // maxX would tie the test to where this text happens to wrap.
        let rightBound = BubbleLayout.sideMargin + floor(width * Theme.bubbleMaxWidthRatio)
        XCTAssertLessThanOrEqual(inset.bubbleFrame.maxX, rightBound)
    }

    // MARK: - The sticky day label

    private func stickyItems() -> [ChatFeedItem] {
        let base: TimeInterval = 1_700_000_000
        return [
            .message(incoming("m3", sentAt: base + 86_400, seq: 3), tightGap: false,
                     showTail: true, showName: false, authorName: nil),
            .dateSeparator(id: "date:m3", label: "Today"),
            .message(incoming("m2", sentAt: base + 60, seq: 2), tightGap: false,
                     showTail: true, showName: false, authorName: nil),
            .message(incoming("m1", sentAt: base, seq: 1), tightGap: false,
                     showTail: true, showName: false, authorName: nil),
            .dateSeparator(id: "date:m1", label: "Yesterday"),
        ]
    }

    /// A message at the top edge names its own day: the nearest separator
    /// above it, which in the inverted array lies at a later index.
    func testStickyLabelNamesTheDayOfTheTopMessage() {
        let items = stickyItems()
        XCTAssertEqual(MessagesViewController.stickyLabel(items: items, topIndex: 0), "Today")
        XCTAssertEqual(MessagesViewController.stickyLabel(items: items, topIndex: 2), "Yesterday")
        XCTAssertEqual(MessagesViewController.stickyLabel(items: items, topIndex: 3), "Yesterday")
    }

    /// The day's own separator at the top edge takes the spot: the floating
    /// capsule yields to the real cell instead of doubling it.
    func testStickyLabelYieldsToTheRealSeparator() {
        let items = stickyItems()
        XCTAssertNil(MessagesViewController.stickyLabel(items: items, topIndex: 1))
        XCTAssertNil(MessagesViewController.stickyLabel(items: items, topIndex: 4))
    }

    /// Nothing above the top item (history start, or an empty feed): no label.
    func testStickyLabelEmptyCases() {
        XCTAssertNil(MessagesViewController.stickyLabel(items: [], topIndex: 0))
        XCTAssertNil(MessagesViewController.stickyLabel(items: stickyItems(), topIndex: nil))
        XCTAssertNil(MessagesViewController.stickyLabel(items: stickyItems(), topIndex: 99))
        // the oldest known message with no separator above it
        let tail: [ChatFeedItem] = [.message(incoming("m1", sentAt: 1_700_000_000, seq: 1),
                                             tightGap: false, showTail: true, showName: false,
                                             authorName: nil)]
        XCTAssertNil(MessagesViewController.stickyLabel(items: tail, topIndex: 0))
    }
}
