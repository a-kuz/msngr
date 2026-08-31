import Foundation

/// The text of a message notification: what shows up in the banner and in the tray.
public struct NotificationContent: Equatable, Sendable {
    /// sender name (in the banner a Communication Notification takes its place)
    public var title: String
    /// group title; nil for 1:1
    public var subtitle: String?
    public var body: String
    /// notifications of one chat are grouped by chatId
    public var threadIdentifier: String

    public init(title: String, subtitle: String?, body: String, threadIdentifier: String) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.threadIdentifier = threadIdentifier
    }
}

/// Builds a notification out of decrypted message content. Shared by the app (local
/// notifications while the socket is up) and the extension (mutating an APNs push),
/// hence no UIKit and no database access: everything it needs arrives as arguments.
public enum NotificationContentBuilder {
    /// The chat the message arrived in.
    public struct ChatInfo: Equatable, Sendable {
        public var chatId: String
        public var isGroup: Bool
        public var title: String?

        public init(chatId: String, isGroup: Bool, title: String?) {
            self.chatId = chatId
            self.isGroup = isGroup
            self.title = title
        }
    }

    /// Who sent the message.
    public struct SenderInfo: Equatable, Sendable {
        public var userId: String
        public var displayName: String
        public var avatarId: String?

        public init(userId: String, displayName: String, avatarId: String? = nil) {
            self.userId = userId
            self.displayName = displayName
            self.avatarId = avatarId
        }
    }

    /// Longest text preview.
    public static let textLimit = 200

    /// Notification body when the privacy setting hides message text.
    public static let hiddenTextBody = CoreStrings.string("New message")

    /// Content kinds that raise no notification: an edit, a reaction, a timer change,
    /// a service row of the feed and a message already deleted.
    public static let silentKinds: Set<String> = ["edit", "reaction", "disappearing", "system", "deleted", "listened"]

    /// nil means this message must raise no notification.
    /// - Parameters:
    ///   - showsMessageText: the "show text in notifications" setting; when false the
    ///     sender name, the group title and the avatar still show.
    ///   - isDeleted: the message was deleted for everyone.
    public static func build(payload: ContentPayload,
                             chat: ChatInfo,
                             sender: SenderInfo,
                             showsMessageText: Bool = true,
                             isDeleted: Bool = false) -> NotificationContent? {
        guard !isDeleted, !silentKinds.contains(payload.kind) else { return nil }
        let name = sender.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let groupTitle = chat.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = name.isEmpty
            ? (chat.isGroup ? (groupTitle ?? CoreStrings.string("Group")) : "Msngr") : name
        return NotificationContent(
            title: title,
            subtitle: chat.isGroup
                ? (groupTitle?.isEmpty == false ? groupTitle : CoreStrings.string("Group")) : nil,
            body: showsMessageText ? preview(payload) : hiddenTextBody,
            threadIdentifier: chat.chatId)
    }

    /// A peer reacted to your message: the sender's name in the title, the
    /// emoji and a quote of the target in the body.
    public static func reactionContent(emoji: String,
                                       targetText: String?,
                                       targetKind: String,
                                       chat: ChatInfo,
                                       sender: SenderInfo,
                                       showsMessageText: Bool = true) -> NotificationContent {
        let name = sender.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let groupTitle = chat.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        var payload = ContentPayload(kind: targetKind)
        payload.text = targetText
        let quote = truncate(preview(payload), limit: 80)
        return NotificationContent(
            title: name.isEmpty
                ? (chat.isGroup ? (groupTitle ?? CoreStrings.string("Group")) : "Msngr") : name,
            subtitle: chat.isGroup
                ? (groupTitle?.isEmpty == false ? groupTitle : CoreStrings.string("Group")) : nil,
            body: showsMessageText
                ? CoreStrings.string("Reacted \(emoji) to “\(quote)”")
                : CoreStrings.string("Reacted \(emoji) to your message"),
            threadIdentifier: chat.chatId)
    }

    /// A request before it is accepted: sender name and avatar stay, content does not.
    public static func requestContent(chat: ChatInfo, sender: SenderInfo) -> NotificationContent {
        let name = sender.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return NotificationContent(
            title: name.isEmpty ? "Msngr" : name,
            subtitle: nil,
            body: ChatPrivacy.requestPlaceholder,
            threadIdentifier: chat.chatId)
    }

    /// The same builder over a message row from the local database, already decrypted.
    public static func build(message: Message,
                             chat: ChatInfo,
                             sender: SenderInfo,
                             showsMessageText: Bool = true) -> NotificationContent? {
        var payload = ContentPayload(kind: message.kind.rawValue)
        payload.text = message.text
        payload.media = message.media
        payload.album = message.album
        return build(payload: payload, chat: chat, sender: sender,
                     showsMessageText: showsMessageText, isDeleted: message.deletedForAll)
    }

    /// One-line preview of the content: the text, or a media placeholder plus caption.
    public static func preview(_ payload: ContentPayload) -> String {
        let caption = truncate(MessageMarkdown.mentionsStripped(payload.text ?? ""))
        switch payload.kind {
        case "photo": return withCaption(CoreStrings.string("📷 Photo"), caption)
        case "video": return withCaption(CoreStrings.string("🎥 Video"), caption)
        case "voice": return withCaption(CoreStrings.string("🎤 Voice message"), caption)
        case "roundVideo": return withCaption(CoreStrings.string("📹 Video message"), caption)
        case "album": return withCaption(CoreStrings.string("🖼 Album"), caption)
        case "contact": return withCaption(CoreStrings.string("👤 Contact"), caption)
        case "shader": return withCaption(CoreStrings.string("✨ Shader"), caption)
        case "sticker": return withCaption(CoreStrings.string("✨ Sticker"), caption)
        case "file":
            let name = payload.media?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            return withCaption("📎 " + (name?.isEmpty == false ? name! : CoreStrings.string("File")), caption)
        default:
            return caption.isEmpty ? hiddenTextBody : caption
        }
    }

    private static func withCaption(_ placeholder: String, _ caption: String) -> String {
        caption.isEmpty ? placeholder : "\(placeholder): \(caption)"
    }

    /// Collapses line breaks and cuts on a word boundary, adding an ellipsis.
    public static func truncate(_ text: String, limit: Int = textLimit) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard flat.count > limit else { return flat }
        let head = String(flat.prefix(limit))
        // word boundary: the last space in the cut-off piece. A single long word is cut
        // at the limit instead, otherwise the notification would come out with no text
        if let space = head.lastIndex(of: " ") {
            let word = head[head.startIndex..<space]
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-—"))
            if !word.isEmpty { return word + "…" }
        }
        return head + "…"
    }
}

/// Notification privacy settings. They live in the app group defaults so that the
/// extension sees them too.
public enum NotificationPreferences {
    public static let showsMessageTextKey = "notifications.showsMessageText"

    /// Text is shown by default.
    public static func showsMessageText(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: showsMessageTextKey) as? Bool ?? true
    }

    public static func setShowsMessageText(_ value: Bool, in defaults: UserDefaults) {
        defaults.set(value, forKey: showsMessageTextKey)
    }
}
