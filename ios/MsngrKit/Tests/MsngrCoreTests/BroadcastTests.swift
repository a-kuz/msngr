import XCTest
@testable import MsngrCore

final class BroadcastTests: XCTestCase {
    /// Каждый подписчик получает каждое значение (у голого AsyncStream
    /// значение достаётся только одному из потребителей).
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

    /// Сценарий залипшего «подключение…»: экран чата подписался и закрылся
    /// (итерация отменена), затем пришёл реконнект. Новый подписчик обязан
    /// получить актуальное состояние — у голого AsyncStream отмена итерации
    /// терминировала continuation и yield(true) терялся навсегда.
    func testResubscribeAfterCancelledConsumerReceivesReconnect() async {
        let b = Broadcast<Bool>(initial: false)
        let consumer = Task {
            for await _ in b.subscribe() {}
        }
        consumer.cancel()
        _ = await consumer.value

        b.send(true) // реконнект после отписки первого экрана

        var it = b.subscribe().makeAsyncIterator()
        let v = await it.next()
        XCTAssertEqual(v, true)
    }

    /// Подписка с initial: первым элементом приходит текущее состояние,
    /// даже если после подписки событий ещё не было.
    func testInitialValueReplayedToLateSubscriber() async {
        let b = Broadcast<Bool>(initial: false)
        var it = b.subscribe().makeAsyncIterator()
        let v = await it.next()
        XCTAssertEqual(v, false)
    }

    /// Отмена одного подписчика не влияет на доставку другому.
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
