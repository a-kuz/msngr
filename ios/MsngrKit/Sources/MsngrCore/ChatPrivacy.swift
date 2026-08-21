import Foundation

/// A chat request: until the recipient accepts it, all they see is that a request
/// exists and who sent it. Text, media, previews and counters are hidden on every
/// surface — the chat feed, the chat list row, the in-app banner, the push body, the badge.
/// Accepting reveals the content; the messages are already in the local database.
public enum ChatPrivacy {
    /// Stand-in text wherever the preview is hidden.
    public static let requestPlaceholder = CoreStrings.string("New message request")

    /// Whether the chat's content is hidden from the current user.
    public static func hidesContent(isRequest: Bool, iAccepted: Bool) -> Bool {
        isRequest && !iAccepted
    }

    public static func hidesContent(_ chat: Chat?) -> Bool {
        guard let chat else { return false }
        return hidesContent(isRequest: chat.isRequest, iAccepted: chat.iAccepted)
    }

    /// Last-message preview; a hidden chat shows the request stand-in instead.
    public static func preview(isRequest: Bool, iAccepted: Bool, content: String?) -> String? {
        hidesContent(isRequest: isRequest, iAccepted: iAccepted) ? requestPlaceholder : content
    }

    /// The unread count that may be shown: a hidden chat does not reveal how many
    /// messages have already arrived.
    public static func visibleUnread(isRequest: Bool, iAccepted: Bool, unreadCount: Int) -> Int {
        hidesContent(isRequest: isRequest, iAccepted: iAccepted) ? 0 : unreadCount
    }
}
