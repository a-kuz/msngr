import Foundation

/// Ordering of a burst of pushes.
///
/// After a long offline APNs hands over up to a hundred pushes at once and in
/// an arbitrary order. The order a user sees in the notification centre is the
/// order the notifications were posted in, so the extension collects what
/// arrives within a short window and posts the whole batch at once, sorted.
/// Reposting what is already on screen is not an option: an `add` with a new
/// identifier is a full delivery with sound, so a message that was already
/// shown must never be shown twice.

/// One push accepted into a window.
public struct BurstItem: Hashable, Sendable {
    public var chatId: String
    /// Position of the message in its chat: with the chat it is the message's
    /// identity, and the order inside a chat.
    public var seq: Int
    /// Send time as the sender stamped it: only compared, never shown. Orders
    /// the chats of a burst between each other.
    public var sentAt: Double

    public init(chatId: String, seq: Int, sentAt: Double) {
        self.chatId = chatId
        self.seq = seq
        self.sentAt = sentAt
    }

    /// Dictionary key of the message the push carries.
    public var key: String { Message.feedId(chatId: chatId, seq: seq) }
}

/// What the local database knows about a message a push arrived for.
public struct BurstItemState: Equatable, Sendable {
    /// A banner for this message has already been presented on this device.
    public var alreadyShown: Bool
    /// `seq <= chat.myReadUpTo`: read here or on another device.
    public var read: Bool
    public var muted: Bool

    public init(alreadyShown: Bool = false, read: Bool = false, muted: Bool = false) {
        self.alreadyShown = alreadyShown
        self.read = read
        self.muted = muted
    }
}

/// What the chat looked like before the burst.
public struct ChatBurstBaseline: Equatable, Sendable {
    /// Highest seq the device knew for the chat.
    public var lastSeq: Int
    /// Seqs the device has already processed above `lastSeq`'s predecessors —
    /// a seq counts as processed when a message row carries it.
    public var knownSeqs: Set<Int>

    public init(lastSeq: Int, knownSeqs: Set<Int> = []) {
        self.lastSeq = lastSeq
        self.knownSeqs = knownSeqs
    }
}

/// Why a push produced no banner.
public enum BurstSkip: String, Equatable, Sendable {
    /// The same message was already answered for, in this window or earlier.
    case duplicate
    /// Read before the banner got its turn.
    case read
    case muted
    /// Nothing to show: the message carries no notifiable content.
    case silent
}

public enum BurstOutcome: Equatable, Sendable {
    case show
    case skip(BurstSkip)
}

/// One push and what to answer it with, in posting position.
public struct BurstStep: Equatable, Sendable {
    /// Position of the item in the batch handed to the planner: every push has
    /// its own content handler and has to be answered individually.
    public var index: Int
    public var item: BurstItem
    public var outcome: BurstOutcome
    /// Filled by the database layer for steps that are shown; nil leaves the
    /// push with the content it arrived with.
    public var content: NotificationContent?

    public init(index: Int, item: BurstItem, outcome: BurstOutcome,
                content: NotificationContent? = nil) {
        self.index = index
        self.item = item
        self.outcome = outcome
        self.content = content
    }
}

/// Seq ranges of a chat that the burst proved to exist and the device does not
/// store.
public struct BurstGap: Equatable, Sendable {
    public var chatId: String
    public var ranges: [ClosedRange<Int>]

    public init(chatId: String, ranges: [ClosedRange<Int>]) {
        self.chatId = chatId
        self.ranges = ranges
    }
}

public struct BurstPlan: Equatable, Sendable {
    public var steps: [BurstStep]
    public var gaps: [BurstGap]

    public init(steps: [BurstStep] = [], gaps: [BurstGap] = []) {
        self.steps = steps
        self.gaps = gaps
    }

    /// Items that get a banner, in posting order.
    public var shown: [BurstItem] { steps.filter { $0.outcome == .show }.map(\.item) }
}

public enum NotificationBurstPlanner {
    /// - Parameters:
    ///   - state: by `BurstItem.key`; a missing entry means the database knows nothing.
    ///   - baseline: by chatId; a missing entry means the chat is unknown here.
    public static func plan(items: [BurstItem],
                            state: [String: BurstItemState] = [:],
                            baseline: [String: ChatBurstBaseline] = [:]) -> BurstPlan {
        let order = ordered(items)
        var seenInWindow: Set<String> = []
        var steps: [BurstStep] = []
        steps.reserveCapacity(order.count)
        for entry in order {
            let s = state[entry.item.key] ?? BurstItemState()
            let outcome: BurstOutcome
            if s.alreadyShown || !seenInWindow.insert(entry.item.key).inserted {
                outcome = .skip(.duplicate)
            } else if s.muted {
                outcome = .skip(.muted)
            } else if s.read {
                outcome = .skip(.read)
            } else {
                outcome = .show
            }
            steps.append(BurstStep(index: entry.index, item: entry.item, outcome: outcome))
        }
        return BurstPlan(steps: steps, gaps: gaps(items: items, baseline: baseline))
    }

    /// Posting order: inside a chat strictly by seq, chats by the send time of
    /// their newest message. The notification centre stacks a chat under one
    /// thread identifier, so the order a user reads is the order inside a chat;
    /// posting the chat with the newest message last puts it on top.
    private static func ordered(_ items: [BurstItem]) -> [(index: Int, item: BurstItem)] {
        let indexed = items.enumerated().map { (index: $0.offset, item: $0.element) }
        var byChat: [String: [(index: Int, item: BurstItem)]] = [:]
        for entry in indexed { byChat[entry.item.chatId, default: []].append(entry) }
        let groups = byChat.map { chatId, entries -> (key: (Double, String), rows: [(index: Int, item: BurstItem)]) in
            let sorted = entries.sorted {
                ($0.item.seq, $0.index) < ($1.item.seq, $1.index)
            }
            let newest = sorted.map(\.item.sentAt).max() ?? 0
            return (key: (newest, chatId), rows: sorted)
        }
        return groups.sorted { $0.key < $1.key }.flatMap(\.rows)
    }

    /// A seq the burst names and the device does not store is a hole: raising
    /// the chat cursor to the top of the burst is what lets the app fetch it.
    private static func gaps(items: [BurstItem],
                             baseline: [String: ChatBurstBaseline]) -> [BurstGap] {
        var out: [BurstGap] = []
        for chatId in Set(items.map(\.chatId)).sorted() {
            let seqs = items.filter { $0.chatId == chatId }.map(\.seq)
            guard let top = seqs.max() else { continue }
            let base = baseline[chatId] ?? ChatBurstBaseline(lastSeq: 0)
            let lower = base.lastSeq + 1
            guard lower <= top else { continue }
            let known = Array(base.knownSeqs) + seqs
            let ranges = HistoryWindow.gaps(known: known, lower: lower, upper: top)
            if !ranges.isEmpty { out.append(BurstGap(chatId: chatId, ranges: ranges)) }
        }
        return out
    }
}
