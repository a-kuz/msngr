import Foundation
import MsngrCore

/// The auto-delete timer new chats start with — local to this device, chosen in
/// Privacy, never sent to the server as a setting. When a chat is created here
/// and the timer is on, one ordinary disappearing message goes out right after
/// creation, the same message the chat info screen sends when its picker moves.
enum DefaultDisappearingTimer: Int, CaseIterable, Identifiable {
    case off = 0
    case day = 86_400
    case week = 604_800
    case month = 2_592_000

    static let key = "defaultDisappearingTTL"
    var id: Int { rawValue }

    var label: String {
        switch self {
        case .off: String(localized: "Off")
        case .day: String(localized: "1 day")
        case .week: String(localized: "1 week")
        case .month: String(localized: "1 month")
        }
    }

    /// The TTL to stamp on a chat this device just created, or nil when nothing
    /// should be sent: the timer is off, the stored value is not one of the
    /// options, or the chat already existed before the call.
    static func ttlForCreatedChat(settingRaw: Int, existedBefore: Bool) -> Int? {
        guard !existedBefore,
              let timer = DefaultDisappearingTimer(rawValue: settingRaw),
              timer != .off else { return nil }
        return timer.rawValue
    }

    /// Sends the disappearing message for a chat this device just created,
    /// when the default timer says one is due.
    static func apply(chatId: String, existedBefore: Bool) async {
        let raw = UserDefaults.standard.integer(forKey: key)
        guard let ttl = ttlForCreatedChat(settingRaw: raw, existedBefore: existedBefore) else { return }
        var c = ContentPayload(kind: "disappearing")
        c.ttlSeconds = ttl
        guard let engine = await MainActor.run(body: { AppState.shared.engine }) else { return }
        do {
            try await engine.enqueue(content: c, chatId: chatId)
        } catch {
            MsngrLog.outbox.error("failed to enqueue default disappearing: \(error)")
        }
    }
}
