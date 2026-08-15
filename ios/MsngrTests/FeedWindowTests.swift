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

    func testPagingUpRaisesTheCeiling() {
        let window = FeedWindow(capacity: 60)
        window.grow(by: 60)
        window.grow(by: 120)
        XCTAssertEqual(window.plan().capacity, 240)
    }

    /// Потолок не даёт окну расти вслед за чатом: сколько бы сообщений ни
    /// пришло, выборка по пересчитанной границе остаётся размером с вместимость,
    /// а её верх — самые новые сообщения.
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
    }
}
