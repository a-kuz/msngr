import XCTest
@testable import MsngrCore

/// The coalescing window and the single chain that answers the pushes: nothing
/// is answered before the window closes, and the answers leave in planned
/// order even though the handlers entered in another one.
final class NotificationBurstGateTests: XCTestCase {
    /// Hands out one permit per `release`, so a test decides when a window ends.
    private actor WindowSignal {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var permits = 0

        func wait() async {
            if permits > 0 {
                permits -= 1
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            if waiters.isEmpty {
                permits += 1
            } else {
                waiters.removeFirst().resume()
            }
        }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var steps: [BurstStep] = []

        func record(_ step: BurstStep) {
            lock.lock()
            steps.append(step)
            lock.unlock()
        }

        var answered: [BurstStep] {
            lock.lock()
            defer { lock.unlock() }
            return steps
        }
    }

    private func item(_ chatId: String, _ seq: Int) -> BurstItem {
        BurstItem(chatId: chatId, msgId: "\(chatId)-\(seq)", seq: seq, sentAt: Double(seq))
    }

    private func gate(_ signal: WindowSignal) -> NotificationBurstGate {
        NotificationBurstGate(window: 0, wait: { _ in await signal.wait() },
                              resolve: { NotificationBurstPlanner.plan(items: $0) })
    }

    private func waitFor(_ recorder: Recorder, count: Int,
                         file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if recorder.answered.count >= count { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("only \(recorder.answered.count) of \(count) pushes answered", file: file, line: line)
    }

    /// Pushes handed over out of order are answered by seq, and none of them is
    /// answered while the window is open.
    func testWindowPostsTheWholeBatchInOrder() async {
        let signal = WindowSignal()
        let gate = gate(signal)
        let recorder = Recorder()

        for seq in [3, 1, 4, 2] {
            await gate.submit(item("c1", seq)) { recorder.record($0) }
        }
        XCTAssertTrue(recorder.answered.isEmpty)

        await signal.release()
        await waitFor(recorder, count: 4)
        XCTAssertEqual(recorder.answered.map(\.item.seq), [1, 2, 3, 4])
    }

    /// The burst outlives the window: what arrives later forms the next batch
    /// and is answered after the first one, never mixed into it.
    func testLateArrivalsFormTheNextBatch() async {
        let signal = WindowSignal()
        let gate = gate(signal)
        let recorder = Recorder()

        for seq in [2, 1] {
            await gate.submit(item("c1", seq)) { recorder.record($0) }
        }
        await signal.release()
        await waitFor(recorder, count: 2)

        for seq in [4, 3] {
            await gate.submit(item("c1", seq)) { recorder.record($0) }
        }
        await signal.release()
        await waitFor(recorder, count: 4)

        XCTAssertEqual(recorder.answered.map(\.item.seq), [1, 2, 3, 4])
    }

    /// Out of time: the window closes at once and the collected pushes are
    /// answered instead of expiring unanswered.
    func testFlushNowClosesTheWindow() async {
        let gate = NotificationBurstGate(window: 60,
                                         resolve: { NotificationBurstPlanner.plan(items: $0) })
        let recorder = Recorder()

        for seq in [2, 1] {
            await gate.submit(item("c1", seq)) { recorder.record($0) }
        }
        await gate.flushNow()
        await waitFor(recorder, count: 2)
        XCTAssertEqual(recorder.answered.map(\.item.seq), [1, 2])
    }

    /// A push the plan says nothing about still gets its answer: an unanswered
    /// handler means a banner that never appears.
    func testPushMissingFromThePlanIsStillAnswered() async {
        let signal = WindowSignal()
        let gate = NotificationBurstGate(window: 0, wait: { _ in await signal.wait() },
                                         resolve: { items in
            BurstPlan(steps: [BurstStep(index: 0, item: items[0], outcome: .show)])
        })
        let recorder = Recorder()

        for seq in [1, 2] {
            await gate.submit(item("c1", seq)) { recorder.record($0) }
        }
        await signal.release()
        await waitFor(recorder, count: 2)
        XCTAssertEqual(recorder.answered.map(\.item.seq).sorted(), [1, 2])
    }
}
