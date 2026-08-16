import XCTest
@testable import MsngrCore

final class BroadcastTests: XCTestCase {
    /// Every subscriber sees every value; a bare AsyncStream hands each value to
    /// only one of its consumers.
    func testEachSubscriberGetsEveryValue() async {
        let b = Broadcast<Int>()
        var it1 = b.subscribe().makeAsyncIterator()
        var it2 = b.subscribe().makeAsyncIterator()
        b.send(1)
        b.send(2)
        let a = (await it1.next(), await it1.next())
        let c = (await it2.next(), await it2.next())
        XCTAssertEqual(a.0, 1)
        XCTAssertEqual(a.1, 2)
        XCTAssertEqual(c.0, 1)
        XCTAssertEqual(c.1, 2)
    }

    /// The stuck "connecting…" case: a chat screen subscribes and then closes,
    /// cancelling its iteration, and the reconnect lands afterwards. The next
    /// subscriber has to see the current state. With a bare AsyncStream the
    /// cancelled iteration terminated the continuation and yield(true) was lost
    /// for good.
    func testResubscribeAfterCancelledConsumerReceivesReconnect() async {
        let b = Broadcast<Bool>(initial: false)
        let consumer = Task {
            for await _ in b.subscribe() {}
        }
        consumer.cancel()
        _ = await consumer.value

        b.send(true) // the reconnect arrives after the first screen unsubscribed

        var it = b.subscribe().makeAsyncIterator()
        let v = await it.next()
        XCTAssertEqual(v, true)
    }

    /// Subscribing with an initial value: the current state arrives as the first
    /// element even when nothing is sent afterwards.
    func testInitialValueReplayedToLateSubscriber() async {
        let b = Broadcast<Bool>(initial: false)
        var it = b.subscribe().makeAsyncIterator()
        let v = await it.next()
        XCTAssertEqual(v, false)
    }

    /// Cancelling one subscriber does not disturb delivery to another.
    func testCancelledSubscriberDoesNotBreakOthers() async {
        let b = Broadcast<Int>()
        var alive = b.subscribe().makeAsyncIterator()
        let dead = Task {
            for await _ in b.subscribe() {}
        }
        dead.cancel()
        _ = await dead.value
        b.send(7)
        let v = await alive.next()
        XCTAssertEqual(v, 7)
    }
}
