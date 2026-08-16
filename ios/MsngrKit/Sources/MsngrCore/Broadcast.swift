import Foundation

/// Multicast on top of AsyncStream: every value reaches every subscriber.
/// A bare AsyncStream hands each value to a single consumer, and cancelling its
/// iteration terminates the continuation, so every later yield is lost to any future
/// subscriber too. Here each subscriber gets its own stream and cancelling one
/// unsubscribes only that subscriber.
public final class Broadcast<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private let replayLast: Bool
    private var last: Element?

    /// replayLast: a new subscriber immediately receives the last value sent, which is
    /// what state like "connected" needs — the current snapshot, not only future changes.
    public init(replayLast: Bool = false) {
        self.replayLast = replayLast
    }

    /// Stream with an initial value: a subscriber gets it, or something newer,
    /// as its first element.
    public convenience init(initial: Element) {
        self.init(replayLast: true)
        last = initial
    }

    public func subscribe() -> AsyncStream<Element> {
        AsyncStream { continuation in
            lock.lock()
            let id = UUID()
            continuations[id] = continuation
            let replay = replayLast ? last : nil
            lock.unlock()
            if let replay { continuation.yield(replay) }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    public func send(_ value: Element) {
        lock.lock()
        if replayLast { last = value }
        let subscribers = Array(continuations.values)
        lock.unlock()
        for c in subscribers { c.yield(value) }
    }
}
