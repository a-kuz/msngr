import Foundation

/// Coalescing window over pushes, and the single chain that answers them.
///
/// The notification service extension is handed one push per message and may be
/// entered several times at once inside one process. Answering a push
/// immediately means the banner order equals the order APNs happened to deliver
/// in, which after a long offline is arbitrary. The gate holds every push that
/// arrives inside `window`, plans the whole batch at once and then answers the
/// pushes one by one in planned order: content handlers are called from inside
/// the actor, so nothing can overtake anything.
///
/// The window costs a fraction of the 30 second budget of the extension, and a
/// burst is delivered by APNs within seconds.
public actor NotificationBurstGate {
    /// Builds the plan for a batch; the database layer supplies it.
    public typealias Resolve = @Sendable ([BurstItem]) async -> BurstPlan
    /// Answers one push. Called from the gate in posting order.
    public typealias Answer = @Sendable (BurstStep) -> Void

    /// Long enough to collect a burst APNs is pushing through, short enough to
    /// stay unnoticed on a single message.
    public static let defaultWindow: TimeInterval = 1.5

    private let window: TimeInterval
    private let wait: @Sendable (TimeInterval) async -> Void
    private let resolve: Resolve
    private var pending: [(item: BurstItem, answer: Answer)] = []
    private var chain: Task<Void, Never>?

    public init(window: TimeInterval = NotificationBurstGate.defaultWindow,
                wait: @escaping @Sendable (TimeInterval) async -> Void = NotificationBurstGate.sleep,
                resolve: @escaping Resolve) {
        self.window = window
        self.wait = wait
        self.resolve = resolve
    }

    public static let sleep: @Sendable (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    /// Accepts a push. Returns once it is registered; the answer comes later,
    /// when the window closes and the batch is posted.
    public func submit(_ item: BurstItem, answer: @escaping Answer) {
        pending.append((item, answer))
        if chain == nil {
            chain = Task { [weak self] in await self?.run() }
        }
    }

    /// The extension is running out of time: close the window now.
    public func flushNow() {
        chain?.cancel()
    }

    /// Pushes waiting for the window to close.
    public var pendingCount: Int { pending.count }

    private func run() async {
        while true {
            await wait(window)
            let batch = pending
            pending = []
            guard !batch.isEmpty else {
                chain = nil
                return
            }
            let plan = await resolve(batch.map(\.item))
            // one chain: the answers are made here, in one hop of the actor,
            // so their order is exactly the planned one
            var answered = Set<Int>()
            for step in plan.steps where batch.indices.contains(step.index) {
                guard answered.insert(step.index).inserted else { continue }
                batch[step.index].answer(step)
            }
            // a push the plan left out still has to be answered, otherwise its
            // banner never appears; the push carries its own content
            for index in batch.indices where !answered.contains(index) {
                batch[index].answer(BurstStep(index: index, item: batch[index].item, outcome: .show))
            }
            if pending.isEmpty {
                chain = nil
                return
            }
        }
    }
}
