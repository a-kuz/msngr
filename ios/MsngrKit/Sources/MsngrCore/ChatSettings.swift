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
        case .hour: return "На час"
        case .eightHours: return "На 8 часов"
        case .week: return "На неделю"
        case .forever: return "Навсегда"
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

    /// "до 14:30" / "до 21 августа" for the row in the chat profile; nil when muted
    /// forever or not muted at all.
    public static func untilLabel(muted: Bool, mutedUntil: Double?,
                                  now: Double = Date().timeIntervalSince1970) -> String? {
        guard isMuted(muted: muted, mutedUntil: mutedUntil, now: now), let mutedUntil else { return nil }
        let date = Date(timeIntervalSince1970: mutedUntil)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "ru_RU")
        fmt.dateFormat = mutedUntil - now < 24 * 3600 ? "HH:mm" : "d MMMM, HH:mm"
        return "до " + fmt.string(from: date)
    }
}

/// What a chat member is allowed to do; mirrors the server's checks in `ConversationDO`.
public enum ChatPermissions {
    public static let adminRole = "admin"

    /// Title, avatar and description: admins only in a group, any member in a direct chat.
    public static func canEditSettings(kind: ChatKind, role: String?) -> Bool {
        guard let role else { return false }
        return kind == .direct || role == adminRole
    }

    /// Only a group admin can remove members.
    public static func canRemoveMembers(kind: ChatKind, role: String?) -> Bool {
        kind == .group && role == adminRole
    }

    /// An admin can add anyone; a non-admin can only add themselves.
    public static func canAddMembers(kind: ChatKind, role: String?, onlySelf: Bool = false) -> Bool {
        guard kind == .group, role != nil else { return false }
        return role == adminRole || onlySelf
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
