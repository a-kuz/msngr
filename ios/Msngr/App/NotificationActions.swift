import Foundation
import UserNotifications
import MsngrCore

/// The actions a message banner offers, and the pure routing of the user's
/// response to one of them.
enum NotificationActions {
    static let replyAction = "reply"
    static let muteAction = "mute"

    /// The category registered at launch; message banners carry its identifier.
    static func messageCategory() -> UNNotificationCategory {
        let reply = UNTextInputNotificationAction(
            identifier: replyAction,
            title: String(localized: "Reply"),
            options: [],
            textInputButtonTitle: String(localized: "Send"),
            textInputPlaceholder: String(localized: "Message"))
        let mute = UNNotificationAction(
            identifier: muteAction,
            title: String(localized: "Mute"),
            options: [])
        return UNNotificationCategory(identifier: NotificationCategory.message,
                                      actions: [reply, mute],
                                      intentIdentifiers: [],
                                      options: [])
    }

    enum Route: Equatable {
        /// the plain tap: open the chat
        case open(chatId: String)
        /// quick reply: send the text into the chat
        case reply(chatId: String, text: String)
        /// mute the chat, forever
        case mute(chatId: String)
        case none
    }

    /// What the app does with a notification response. Pure: the caller passes
    /// the action identifier, the chatId from userInfo and the typed text.
    static func route(actionIdentifier: String, chatId: String?, userText: String?) -> Route {
        guard let chatId, !chatId.isEmpty else { return .none }
        switch actionIdentifier {
        case replyAction:
            let text = (userText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .none : .reply(chatId: chatId, text: text)
        case muteAction:
            return .mute(chatId: chatId)
        case UNNotificationDefaultActionIdentifier:
            return .open(chatId: chatId)
        default:
            return .none
        }
    }
}
