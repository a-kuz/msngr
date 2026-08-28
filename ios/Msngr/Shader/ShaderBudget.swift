import UIKit

/// How many shaders draw at once. A screen can hold more canvases than the
/// GPU should be asked to animate: a feed of shader messages, a background, a
/// dozen shader avatars in the chat list. The canvases that want to run
/// register here; the top `maxLive` by priority and recency animate, the rest
/// render one frame and hold it until a slot frees up.
@MainActor
final class ShaderBudget {
    static let shared = ShaderBudget()

    /// Four animating shaders keep 60 fps on the slowest phone we ship to;
    /// the fifth is where the feed starts to stutter.
    static let maxLive = 4

    private struct Entry {
        weak var canvas: ShaderCanvas?
        let since: CFTimeInterval
    }

    private var wanting: [ObjectIdentifier: Entry] = [:]

    /// A canvas that wants to animate. The most recent ask wins a slot from an
    /// older one of the same priority: the message that just scrolled in runs
    /// while the one about to leave holds its frame.
    func request(_ canvas: ShaderCanvas) {
        let id = ObjectIdentifier(canvas)
        if wanting[id] == nil {
            wanting[id] = Entry(canvas: canvas, since: CACurrentMediaTime())
        }
        rebalance()
    }

    func release(_ canvas: ShaderCanvas) {
        guard wanting.removeValue(forKey: ObjectIdentifier(canvas)) != nil else { return }
        rebalance()
    }

    /// Live shaders on screen right now, for the run reports.
    var liveCount: Int { wanting.values.filter { $0.canvas?.isLive == true }.count }

    private func rebalance() {
        var alive: [(ShaderCanvas, CFTimeInterval)] = []
        for (id, e) in wanting {
            if let c = e.canvas { alive.append((c, e.since)) } else { wanting[id] = nil }
        }
        alive.sort { a, b in
            if a.0.priority != b.0.priority { return a.0.priority.rawValue > b.0.priority.rawValue }
            return a.1 > b.1
        }
        for (i, (canvas, _)) in alive.enumerated() {
            canvas.applyBudget(live: i < Self.maxLive)
        }
    }
}
