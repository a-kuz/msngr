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
///
/// The capacity comes back down as well: paging up raises it, and coming back to the end
/// of the chat returns it to a page. A jump into the history holds its target between two
/// bounds instead of reaching the newest message, so the size of the window does not
/// depend on how deep the jump went.
final class FeedWindow: @unchecked Sendable {
    /// What to put into the fetch, and whether the bound has to be recomputed first.
    struct Plan: Equatable {
        let floor: Int?
        let recompute: Bool
        let capacity: Int
    }

    /// Messages a jump keeps below its target: what the reader scrolls up into before
    /// pagination has to go to the database again.
    static let anchorBelow = HistoryWindow.pageSize
    /// Messages a jump holds in total, the target among them.
    static let anchorCapacity = HistoryWindow.pageSize * 3

    private let lock = NSLock()
    private let pageSize: Int
    private var seq: Int?
    private var capacity: Int
    private var atBottom = true
    /// The window stands on a jump target rather than at the end of the chat: its bound
    /// is held even when the feed reports that it is at the bottom, because the bottom
    /// of an anchored window is not the newest message.
    private var anchored = false

    init(capacity: Int = HistoryWindow.pageSize) {
        self.capacity = capacity
        self.pageSize = capacity
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
        return Plan(floor: seq, recompute: !anchored && (seq == nil || atBottom), capacity: capacity)
    }

    /// The reader pulled in more history: the window may hold that many more.
    func grow(by count: Int) {
        lock.lock(); capacity += count; lock.unlock()
    }

    /// Jumping to a message deeper than the window: the bound lands a page below it and
    /// the capacity holds it with history on both sides. The window stops following the
    /// end of the chat until the reader asks for it again.
    func anchor(floor: Int, capacity: Int = FeedWindow.anchorCapacity) {
        lock.lock()
        seq = floor
        self.capacity = capacity
        anchored = true
        lock.unlock()
    }

    /// The window turned out to reach the newest message after all: it can follow the
    /// end of the chat again.
    func releaseAnchor() {
        lock.lock(); anchored = false; lock.unlock()
    }

    /// Back to a page at the end of the chat, from wherever in the history the window
    /// stood.
    func reset() {
        lock.lock()
        seq = nil
        capacity = pageSize
        anchored = false
        atBottom = true
        lock.unlock()
    }

    /// Reports where the feed is standing. Returning to the bottom gives the pages the
    /// reader paged in back: the window is a page again, and the next fetch is the size
    /// it is on entering the chat. Answers whether the capacity actually came down, so
    /// the caller can refetch on the smaller window.
    @discardableResult
    func setAtBottom(_ value: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        atBottom = value
        guard value, !anchored, capacity > pageSize else { return false }
        capacity = pageSize
        return true
    }
}
