import XCTest
import MsngrCore
@testable import Msngr

final class FeedWindowTests: XCTestCase {
    func testSlidesWhileFeedIsAtBottom() {
        let window = FeedWindow(capacity: 60)
        window.set(100)
        let plan = window.plan()
        XCTAssertTrue(plan.recompute)
        XCTAssertEqual(plan.capacity, 60)
    }

    func testFloorStaysPutWhileReadingOlderMessages() {
        let window = FeedWindow(capacity: 60)
        window.set(100)
        window.setAtBottom(false)
        XCTAssertEqual(window.plan(), FeedWindow.Plan(floor: 100, recompute: false, capacity: 60))
    }

    func testFirstFetchAlwaysComputesTheFloor() {
        let window = FeedWindow(capacity: 60)
        window.setAtBottom(false)
        XCTAssertTrue(window.plan().recompute)
    }

    /// Jumping to a message deeper than the window: the floor lands on it and the
    /// window holds a bounded number of messages around it, however far the end of
    /// the conversation is from there.
    func testAnchorHoldsTheTargetWithinBounds() {
        let window = FeedWindow(capacity: 60)
        window.set(19_900)
        window.anchor(floor: 440)
        XCTAssertEqual(window.plan().floor, 440)
        XCTAssertEqual(window.plan().capacity, FeedWindow.anchorCapacity)
    }

    /// A window paging had already grown comes back to the size of a jump: the pages
    /// that were read on the way up are far from the target and cost a refetch each.
    func testAnchorBoundsAWindowThatPagingHadGrown() {
        let window = FeedWindow(capacity: 60)
        window.grow(by: 6_000)
        window.anchor(floor: 10)
        XCTAssertEqual(window.plan().capacity, FeedWindow.anchorCapacity)
    }

    /// The feed reporting that it is at the bottom does not move an anchored window:
    /// the bottom of a window standing in the history is not the newest message, and
    /// recomputing the floor there would take the reader away from the target.
    func testAnchoredWindowDoesNotFollowTheEndOfTheChat() {
        let window = FeedWindow(capacity: 60)
        window.anchor(floor: 500)
        window.setAtBottom(true)
        XCTAssertEqual(window.plan(), FeedWindow.Plan(floor: 500, recompute: false,
                                                      capacity: FeedWindow.anchorCapacity))
    }

    /// A jump that landed near the end of the chat holds the newest message anyway,
    /// and the window is free to follow it again.
    func testReleasedAnchorLetsTheWindowSlideAgain() {
        let window = FeedWindow(capacity: 60)
        window.anchor(floor: 500)
        window.releaseAnchor()
        XCTAssertTrue(window.plan().recompute)
    }

    /// Coming back to the bottom gives the pages back: the window is a page again and
    /// the caller is told to refetch on it.
    func testReturningToTheBottomShrinksTheWindowToAPage() {
        let window = FeedWindow(capacity: 60)
        window.set(1_000)
        window.setAtBottom(false)
        window.grow(by: 840)
        XCTAssertEqual(window.plan().capacity, 900)

        XCTAssertTrue(window.setAtBottom(true))
        XCTAssertEqual(window.plan().capacity, 60)
        // already a page: nothing to shrink and nothing to refetch
        XCTAssertFalse(window.setAtBottom(true))
    }

    /// The reader asked for the newest messages: the window leaves the history it
    /// stood in, whatever it had grown to.
    func testResetReturnsTheWindowToTheEndOfTheChat() {
        let window = FeedWindow(capacity: 60)
        window.anchor(floor: 500)
        window.grow(by: 300)
        window.reset()
        XCTAssertEqual(window.plan(), FeedWindow.Plan(floor: nil, recompute: true, capacity: 60))
    }

    func testPagingUpRaisesTheCeiling() {
        let window = FeedWindow(capacity: 60)
        window.grow(by: 60)
        window.grow(by: 120)
        XCTAssertEqual(window.plan().capacity, 240)
    }

    /// The ceiling keeps the window from growing along with the chat: however many
    /// messages arrive, the fetch from the recomputed floor stays the size of the
    /// capacity and its top holds the newest messages.
    func testCeilingBoundsTheWindowOverALongChat() throws {
        let db = try AppDatabase.openInMemory()
        try db.write { dbc in
            try dbc.execute(sql: """
                INSERT INTO chat (id, kind, title, createdBy, createdAt)
                VALUES ('c', 'direct', 'c', 'peer', 1700000000)
                """)
            for seq in 1...5_000 {
                try dbc.execute(sql: """
                    INSERT INTO message (id, msgId, chatId, seq, fromUserId, sentAt, kind, text,
                                         edited, deletedForAll, status, isOutgoing)
                    VALUES (?,?,?,?,?,?,?,?,0,0,2,0)
                    """, arguments: ["m\(seq)", "m\(seq)", "c", seq, "peer",
                                     1_700_000_000 + Double(seq), "text", "m\(seq)"])
            }
        }
        try db.read { dbc in
            let floor = try HistoryWindow.newestFloor(dbc, chatId: "c", limit: 60)
            let msgs = try HistoryWindow.messages(dbc, chatId: "c", floor: floor)
            XCTAssertEqual(msgs.count, 60)
            XCTAssertEqual(msgs.first?.seq, 5_000)
            XCTAssertEqual(msgs.last?.seq, 4_941)
        }
    }

    /// The reader is looking at older messages, so the floor stays where it is.
    /// The window still holds no more than its capacity: the messages arriving
    /// below are outside it until the reader comes back down.
    func testFrozenFloorStillBoundsTheWindow() throws {
        let db = try AppDatabase.openInMemory()
        try db.write { dbc in
            try dbc.execute(sql: """
                INSERT INTO chat (id, kind, title, createdBy, createdAt)
                VALUES ('c', 'direct', 'c', 'peer', 1700000000)
                """)
            for seq in 1...5_000 {
                try dbc.execute(sql: """
                    INSERT INTO message (id, msgId, chatId, seq, fromUserId, sentAt, kind, text,
                                         edited, deletedForAll, status, isOutgoing)
                    VALUES (?,?,?,?,?,?,?,?,0,0,2,0)
                    """, arguments: ["m\(seq)", "m\(seq)", "c", seq, "peer",
                                     1_700_000_000 + Double(seq), "text", "m\(seq)"])
            }
        }
        let window = FeedWindow(capacity: 60)
        window.set(1_000)
        window.setAtBottom(false)
        let plan = window.plan()
        XCTAssertFalse(plan.recompute)
        try db.read { dbc in
            let msgs = try HistoryWindow.messages(dbc, chatId: "c", floor: plan.floor,
                                                  limit: plan.capacity)
            XCTAssertEqual(msgs.count, 60)
            XCTAssertEqual(msgs.last?.seq, 1_000, "the frozen floor is still the bottom of the window")
            XCTAssertEqual(msgs.first?.seq, 1_059)
        }
        // sending from up in the history returns the window to the newest
        // messages, or the sent message would stay outside it
        window.setAtBottom(true)
        let afterSend = window.plan()
        XCTAssertTrue(afterSend.recompute)
        try db.read { dbc in
            let floor = try HistoryWindow.newestFloor(dbc, chatId: "c", limit: afterSend.capacity)
            let msgs = try HistoryWindow.messages(dbc, chatId: "c", floor: floor)
            XCTAssertEqual(msgs.first?.seq, 5_000, "the newest message is back in the window")
        }
    }

    /// Only an own message with a bubble moves the feed to the end of the chat.
    func testOnlyOwnBubbleMovesFeedToEnd() {
        XCTAssertTrue(ChatViewModel.movesFeedToEnd(kind: "text", target: "c", chatId: "c"))
        XCTAssertTrue(ChatViewModel.movesFeedToEnd(kind: "photo", target: "c", chatId: "c"))
        XCTAssertFalse(ChatViewModel.movesFeedToEnd(kind: "reaction", target: "c", chatId: "c"))
        XCTAssertFalse(ChatViewModel.movesFeedToEnd(kind: "edit", target: "c", chatId: "c"))
        XCTAssertFalse(ChatViewModel.movesFeedToEnd(kind: "text", target: "other", chatId: "c"),
                       "a forward into another chat does not move the feed")
    }

    /// A jump into the middle of a long chat: the window holds the target with history
    /// under it and messages above it, and stops there instead of reaching the newest
    /// message four and a half thousand rows away.
    func testJumpHoldsItsTargetWithoutReachingTheNewest() throws {
        let db = try AppDatabase.openInMemory()
        try db.write { dbc in
            try dbc.execute(sql: """
                INSERT INTO chat (id, kind, title, createdBy, createdAt)
                VALUES ('c', 'direct', 'c', 'peer', 1700000000)
                """)
            for seq in 1...5_000 {
                try dbc.execute(sql: """
                    INSERT INTO message (id, msgId, chatId, seq, fromUserId, sentAt, kind, text,
                                         edited, deletedForAll, status, isOutgoing)
                    VALUES (?,?,?,?,?,?,?,?,0,0,2,0)
                    """, arguments: ["m\(seq)", "m\(seq)", "c", seq, "peer",
                                     1_700_000_000 + Double(seq), "text", "m\(seq)"])
            }
        }
        let window = FeedWindow(capacity: 60)
        let floor = try db.read { dbc in
            try HistoryWindow.floorBelow(dbc, chatId: "c", floor: 500,
                                         limit: FeedWindow.anchorBelow)
        }
        window.anchor(floor: try XCTUnwrap(floor))
        let plan = window.plan()
        try db.read { dbc in
            let msgs = try HistoryWindow.messages(dbc, chatId: "c", floor: plan.floor,
                                                  limit: plan.capacity)
            XCTAssertEqual(msgs.count, FeedWindow.anchorCapacity)
            XCTAssertEqual(msgs.last?.seq, 440)
            XCTAssertTrue(msgs.contains { $0.seq == 500 })
            XCTAssertTrue(try HistoryWindow.hasNewer(dbc, chatId: "c", topSeq: msgs.first?.seq),
                          "the window stops short of the end of the chat")
        }
    }
}
