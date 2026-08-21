import Foundation

/// How long a chat stays muted.
public enum MuteOption: String, CaseIterable, Sendable {
    case hour, eightHours, week, forever

    public var seconds: Double? {
        switch self {
        case .hour: return 3600
        case .eightHours: return 8 * 3600
        case .week: return 7 * 24 * 3600
        case .forever: return nil
        }
    }

    public var title: String {
        switch self {
        case .hour: return CoreStrings.string("For an hour")
        case .eightHours: return CoreStrings.string("For 8 hours")
        case .week: return CoreStrings.string("For a week")
        case .forever: return CoreStrings.string("Forever")
        }
    }

    /// When the mute lifts; nil means never.
    public func until(from now: Double = Date().timeIntervalSince1970) -> Double? {
        seconds.map { now + $0 }
    }
}

/// Mute with an expiry. `mutedUntil == nil` together with `muted == true` means muted forever.
public enum MuteState {
    public static func isMuted(muted: Bool, mutedUntil: Double?,
                               now: Double = Date().timeIntervalSince1970) -> Bool {
        guard muted else { return false }
        guard let mutedUntil else { return true }
        return mutedUntil > now
    }

    /// The expiry has passed, so the flag should be cleared in the database and on the server.
    public static func isExpired(muted: Bool, mutedUntil: Double?,
                                 now: Double = Date().timeIntervalSince1970) -> Bool {
        guard muted, let mutedUntil else { return false }
        return mutedUntil <= now
    }

    /// Localized "until <time>" / "until <date>" for the row in the chat profile; nil when muted
    /// forever or not muted at all.
    public static func untilLabel(muted: Bool, mutedUntil: Double?,
                                  now: Double = Date().timeIntervalSince1970) -> String? {
        guard isMuted(muted: muted, mutedUntil: mutedUntil, now: now), let mutedUntil else { return nil }
        let date = Date(timeIntervalSince1970: mutedUntil)
        let fmt = DateFormatter()
        if mutedUntil - now < 24 * 3600 {
            fmt.dateFormat = "HH:mm"
        } else {
            fmt.setLocalizedDateFormatFromTemplate("dMMMMHHmm")
        }
        return CoreStrings.string("until \(fmt.string(from: date))")
    }
}

/// What a chat member is allowed to do; mirrors the server's checks in `ConversationDO`.
public enum ChatPermissions {
    public static let adminRole = "admin"
    /// A right the whole group holds.
    public static let openPolicy = "all"
    /// A right only admins hold.
    public static let adminPolicy = "admins"

    /// Title, avatar and description: admins only in a group, any member in a direct chat.
    public static func canEditSettings(kind: ChatKind, role: String?) -> Bool {
        guard let role else { return false }
        return kind == .direct || role == adminRole
    }

    /// Only a group admin can remove members.
    public static func canRemoveMembers(kind: ChatKind, role: String?) -> Bool {
        kind == .group && role == adminRole
    }

    /// Writing to the chat. A group whose `sendPolicy` is `admins` is read-only
    /// for everyone else; service content (a key handout, a repair, a reaction)
    /// travels regardless, which is why this is asked about the input field
    /// alone.
    public static func canSend(kind: ChatKind, role: String?, sendPolicy: String) -> Bool {
        guard kind == .group else { return true }
        guard let role else { return false }
        return sendPolicy != adminPolicy || role == adminRole
    }

    /// Adding a member and minting an invite link, under the group's `invitePolicy`.
    public static func canInvite(kind: ChatKind, role: String?, invitePolicy: String) -> Bool {
        guard kind == .group, let role else { return false }
        return invitePolicy != adminPolicy || role == adminRole
    }

    /// Only an admin can grant and revoke admin rights.
    public static func canManageAdmins(kind: ChatKind, role: String?) -> Bool {
        kind == .group && role == adminRole
    }

    /// Any member of a group can leave it.
    public static func canLeave(kind: ChatKind, role: String?) -> Bool {
        kind == .group && role != nil
    }
}
