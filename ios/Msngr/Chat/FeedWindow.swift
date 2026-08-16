import Foundation
import MsngrCore

/// The lower bound of the feed window and its capacity. The observation reads this state
/// on every fetch, from the database queue, so access goes under a lock.
///
/// The window holds no more than `capacity` messages in either position of the feed. At
/// the bottom it slides: the bound is recomputed from the capacity and arriving messages
/// push the oldest ones out. While the reader is in the history the bound stays put, so
/// nothing already read moves away, and the capacity cuts off everything that arrived in
/// the meantime from the top. Without that ceiling the window grows for as long as the
/// chat is open, and every insert re-reads, decodes and diffs everything piled up in it.
final class FeedWindow: @unchecked Sendable {
    /// What to put into the fetch, and whether the bound has to be recomputed first.
    struct Plan: Equatable {
        let floor: Int?
        let recompute: Bool
        let capacity: Int
    }

    private let lock = NSLock()
    private var seq: Int?
    private var capacity: Int
    private var atBottom = true

    init(capacity: Int = HistoryWindow.pageSize) {
        self.capacity = capacity
    }

    func get() -> Int? {
        lock.lock(); defer { lock.unlock() }
        return seq
    }

    func set(_ value: Int?) {
        lock.lock(); seq = value; lock.unlock()
    }

    func plan() -> Plan {
        lock.lock(); defer { lock.unlock() }
        return Plan(floor: seq, recompute: seq == nil || atBottom, capacity: capacity)
    }

    /// The reader pulled in more history: the window may hold that many more.
    func grow(by count: Int) {
        lock.lock(); capacity += count; lock.unlock()
    }

    /// Jumping to a message deeper than the window: the bound lands right on it and the
    /// capacity stretches up to the newest message, so from the landing point there is
    /// still a way down to the end of the conversation.
    func anchor(floor: Int, capacity: Int) {
        lock.lock()
        seq = floor
        self.capacity = max(self.capacity, capacity)
        lock.unlock()
    }

    func setAtBottom(_ value: Bool) {
        lock.lock(); atBottom = value; lock.unlock()
    }
}
