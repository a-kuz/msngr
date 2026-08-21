import Foundation

/// What happened to a group, as a line in its feed.
///
/// The event is sent by whoever performed it, service-flagged: it takes a seq
/// and reaches everyone, but raises no unread count and no push. Unlike the
/// other service kinds it does leave a row — a system message, rendered as a
/// sentence by `sentence(isOwn:)`.
///
/// The names travel inside the event instead of being looked up when the row is
/// drawn: whoever left is no longer in the member table, and a chat opened a
/// month later should still read the same way.
public struct GroupEvent: Codable, Equatable, Sendable {
    public enum Verb: String, Codable, Sendable {
        /// brought in by the actor
        case added
        case left
        case removed
        case adminGranted
        case adminRevoked
        case title
        case avatar
        case description
        case descriptionCleared
    }

    public var verb: Verb
    /// display name of whoever performed the event
    public var actor: String
    /// display name of the member the event concerns
    public var member: String?
    /// that member's userId, so the one it happened to reads "you"
    public var memberId: String?
    /// the new title
    public var text: String?

    public init(verb: Verb, actor: String, member: String? = nil, memberId: String? = nil,
                text: String? = nil) {
        self.verb = verb
        self.actor = actor
        self.member = member
        self.memberId = memberId
        self.text = text
    }

    /// The `ContentPayload` kind a group event travels under.
    public static let kind = "groupEvent"
    /// Marks the text of a system message as a group event.
    public static let prefix = "group:"

    /// The form the message row and the envelope carry.
    public var encoded: String {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else { return Self.prefix }
        return Self.prefix + json
    }

    public static func decode(_ text: String?) -> GroupEvent? {
        guard let text, text.hasPrefix(prefix) else { return nil }
        let json = String(text.dropFirst(prefix.count))
        return try? JSONDecoder().decode(GroupEvent.self, from: Data(json.utf8))
    }

    /// The event as a human sentence. `isOwn` is for the reader who performed
    /// it and `ownUserId` for the one it happened to.
    public func sentence(isOwn: Bool, ownUserId: String? = nil) -> String {
        let who = isOwn ? CoreStrings.string("You") : actor
        let name = member ?? actor
        let aboutMe = memberId != nil && memberId == ownUserId
        switch verb {
        case .added:
            if aboutMe { return CoreStrings.string("\(who) added you") }
            return isOwn ? CoreStrings.string("You added: \(name)")
                         : CoreStrings.string("\(who) added: \(name)")
        case .left:
            return isOwn ? CoreStrings.string("You left the group")
                         : CoreStrings.string("\(name) left the group")
        case .removed:
            if aboutMe { return CoreStrings.string("\(who) removed you") }
            return isOwn ? CoreStrings.string("You removed: \(name)")
                         : CoreStrings.string("\(who) removed: \(name)")
        case .adminGranted:
            if aboutMe { return CoreStrings.string("\(who) made you an admin") }
            return isOwn ? CoreStrings.string("You made an admin of: \(name)")
                         : CoreStrings.string("\(who) made an admin of: \(name)")
        case .adminRevoked:
            if aboutMe { return CoreStrings.string("\(who) revoked your admin rights") }
            return isOwn ? CoreStrings.string("You revoked admin rights from: \(name)")
                         : CoreStrings.string("\(who) revoked admin rights from: \(name)")
        case .title:
            let title = text ?? ""
            return isOwn ? CoreStrings.string("You renamed the group to “\(title)”")
                         : CoreStrings.string("\(who) renamed the group to “\(title)”")
        case .avatar:
            return isOwn ? CoreStrings.string("You updated the group photo")
                         : CoreStrings.string("\(who) updated the group photo")
        case .description:
            return isOwn ? CoreStrings.string("You changed the group description")
                         : CoreStrings.string("\(who) changed the group description")
        case .descriptionCleared:
            return isOwn ? CoreStrings.string("You removed the group description")
                         : CoreStrings.string("\(who) removed the group description")
        }
    }
}
