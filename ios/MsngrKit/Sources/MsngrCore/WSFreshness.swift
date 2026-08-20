import Foundation

/// What a socket's own clock says about it. The client asks this once a second
/// instead of reacting to callbacks: a stream that goes silent answers nothing
/// at all, so the only thing that catches it is a check that runs on its own.
public enum WSFreshness {
    /// What the watchdog does on this tick.
    public enum Verdict: Equatable {
        case wait
        /// nothing has come for a while: ask, and expect a pong
        case ping
        /// the socket is gone — closed, stalled, or never confirmed
        case dead
    }

    /// An upgrade that never brought its first frame.
    public static let handshake: TimeInterval = 8
    /// A pong is a round trip on a live socket, and a slow network is still
    /// nothing like this long.
    public static let pong: TimeInterval = 4
    /// Silence that earns a ping. Presence on the server lives off ping
    /// freshness with a TTL of 35 s, so asking after 12 s of quiet keeps it warm.
    public static let quiet: TimeInterval = 12

    /// - Parameters:
    ///   - connected: the first frame from the server has arrived
    ///   - openedAt: when the upgrade was started
    ///   - lastFrameAt: when anything last came from the server
    ///   - pingSentAt: when the outstanding ping went out, nil when none is
    public static func decide(now: Date, connected: Bool, openedAt: Date,
                              lastFrameAt: Date?, pingSentAt: Date?) -> Verdict {
        guard connected else {
            return now.timeIntervalSince(openedAt) > handshake ? .dead : .wait
        }
        if let pingSentAt, now.timeIntervalSince(pingSentAt) > pong { return .dead }
        if pingSentAt != nil { return .wait }
        let quietSince = lastFrameAt ?? openedAt
        return now.timeIntervalSince(quietSince) > quiet ? .ping : .wait
    }
}
