import Foundation

/// Срок, на который выключают звук чата.
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

    /// Момент снятия mute; nil — бессрочно.
    public func until(from now: Double = Date().timeIntervalSince1970) -> Double? {
        seconds.map { now + $0 }
    }
}

/// Mute со сроком. `mutedUntil == nil` при `muted == true` — бессрочный mute.
public enum MuteState {
    public static func isMuted(muted: Bool, mutedUntil: Double?,
                               now: Double = Date().timeIntervalSince1970) -> Bool {
        guard muted else { return false }
        guard let mutedUntil else { return true }
        return mutedUntil > now
    }

    /// Срок вышел — флаг пора снять (в БД и на сервере).
    public static func isExpired(muted: Bool, mutedUntil: Double?,
                                 now: Double = Date().timeIntervalSince1970) -> Bool {
        guard muted, let mutedUntil else { return false }
        return mutedUntil <= now
    }

    /// «до 14:30» / «до 21 августа» для строки в профиле чата; nil — бессрочно или не замьючен.
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

/// Права участника чата — зеркало проверок сервера (`ConversationDO`).
public enum ChatPermissions {
    public static let adminRole = "admin"

    /// Название, аватар и описание: в группе — только админ, в direct — любой участник.
    public static func canEditSettings(kind: ChatKind, role: String?) -> Bool {
        guard let role else { return false }
        return kind == .direct || role == adminRole
    }

    /// Удалять участников может только админ группы.
    public static func canRemoveMembers(kind: ChatKind, role: String?) -> Bool {
        kind == .group && role == adminRole
    }

    /// Добавить может админ; не-админ — только самого себя.
    public static func canAddMembers(kind: ChatKind, role: String?, onlySelf: Bool = false) -> Bool {
        guard kind == .group, role != nil else { return false }
        return role == adminRole || onlySelf
    }

    /// Назначать и снимать админов может только админ.
    public static func canManageAdmins(kind: ChatKind, role: String?) -> Bool {
        kind == .group && role == adminRole
    }

    /// Покинуть группу может любой её участник.
    public static func canLeave(kind: ChatKind, role: String?) -> Bool {
        kind == .group && role != nil
    }
}
