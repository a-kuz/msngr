import XCTest
@testable import MsngrCore

/// Which item leaves the outbox next. One chat's backlog — a wave of repair
/// answers runs to thousands of frames — must not hold every other chat's
/// messages behind it, while the order inside a chat stays as it was written.
final class OutboxFairnessTests: XCTestCase {
    private func item(_ id: String, chat: String, at: Double) -> OutboxItem {
        OutboxItem(clientMsgId: id, chatId: chat, createdAt: at, payload: Data())
    }

    func testTheChatsTakeTurns() {
        let ready = [item("a1", chat: "flooded", at: 1),
                     item("a2", chat: "flooded", at: 2),
                     item("a3", chat: "flooded", at: 3),
                     item("b1", chat: "other", at: 4)]

        let first = SyncEngine.nextToSend(ready, skipped: [], after: nil)
        XCTAssertEqual(first?.clientMsgId, "a1", "the oldest item goes first")

        let second = SyncEngine.nextToSend(ready, skipped: [], after: "flooded")
        XCTAssertEqual(second?.clientMsgId, "b1",
                       "the other chat's message waited behind the whole backlog")

        let third = SyncEngine.nextToSend(ready, skipped: [], after: "other")
        XCTAssertEqual(third?.clientMsgId, "a1", "and the turn comes back")
    }

    /// Inside one chat nothing is reordered: the next turn of a chat takes its
    /// oldest waiting item.
    func testTheOrderInsideAChatIsKept() {
        let ready = [item("a1", chat: "c", at: 1),
                     item("a2", chat: "c", at: 2),
                     item("a3", chat: "c", at: 3)]
        XCTAssertEqual(SyncEngine.nextToSend(ready, skipped: [], after: "c")?.clientMsgId, "a1")
        XCTAssertEqual(SyncEngine.nextToSend(ready, skipped: ["a1"], after: "c")?.clientMsgId, "a2")
    }

    func testAnEmptyQueueSendsNothing() {
        XCTAssertNil(SyncEngine.nextToSend([], skipped: [], after: nil))
        XCTAssertNil(SyncEngine.nextToSend([item("a1", chat: "c", at: 1)],
                                           skipped: ["a1"], after: nil))
    }

    /// The chat that sent last has drained: the turn starts again from the
    /// oldest item rather than falling off the end of the rotation.
    func testAChatThatDrainedDoesNotStopTheRotation() {
        let ready = [item("b1", chat: "other", at: 4)]
        XCTAssertEqual(SyncEngine.nextToSend(ready, skipped: [], after: "flooded")?.clientMsgId, "b1")
    }
}
