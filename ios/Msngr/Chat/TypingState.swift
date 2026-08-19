import Foundation

/// Who is typing in an open chat right now.
///
/// The sender repeats its frame while the field keeps changing, and its stop can be
/// lost, so an entry lives for `ttl` after the last frame from that user and then
/// falls out on its own. Every user carries its own deadline: in a group one person
/// going quiet must not take the rest of them off the header.
struct TypingState: Equatable {
    static let ttl: TimeInterval = 5

    /// In the order the frames arrived: the group header names the first of them.
    private(set) var users: [String] = []
    private var lastFrame: [String: Date] = [:]

    var isEmpty: Bool { users.isEmpty }

    mutating func began(_ userId: String, at now: Date) {
        if !users.contains(userId) { users.append(userId) }
        lastFrame[userId] = now
    }

    mutating func ended(_ userId: String) {
        users.removeAll { $0 == userId }
        lastFrame[userId] = nil
    }

    /// Takes off whoever has been quiet for longer than the ttl.
    mutating func expire(at now: Date) {
        for id in users where now.timeIntervalSince(lastFrame[id] ?? .distantPast) >= Self.ttl {
            ended(id)
        }
    }

    /// When the earliest entry falls out, or nil while nobody is typing.
    func nextExpiry() -> Date? {
        lastFrame.values.min().map { $0.addingTimeInterval(Self.ttl) }
    }
}
