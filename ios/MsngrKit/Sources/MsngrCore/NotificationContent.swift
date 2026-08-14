import Foundation

/// Текстовая часть уведомления о сообщении: то, что видно в баннере и в шторке.
public struct NotificationContent: Equatable, Sendable {
    /// имя отправителя (в баннере его заменяет собой Communication Notification)
    public var title: String
    /// название группы; у 1:1 — nil
    public var subtitle: String?
    public var body: String
    /// группировка уведомлений одного чата = chatId
    public var threadIdentifier: String

    public init(title: String, subtitle: String?, body: String, threadIdentifier: String) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.threadIdentifier = threadIdentifier
    }
}

/// Собирает уведомление из расшифрованного контента сообщения. Общий код
/// приложения (локальные уведомления при живом WS) и NSE (мутация APNs-пуша),
/// поэтому без UIKit и без обращений к БД: всё нужное приходит аргументами.
public enum NotificationContentBuilder {
    /// Чат, в который пришло сообщение.
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

    /// Отправитель сообщения.
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

    /// Максимальная длина превью текста.
    public static let textLimit = 200

    /// Тело уведомления, когда показ текста выключен настройкой приватности.
    public static let hiddenTextBody = "Новое сообщение"

    /// Виды контента, о которых уведомление не показывается: правка, реакция,
    /// смена таймера, служебная запись ленты и уже удалённое сообщение.
    public static let silentKinds: Set<String> = ["edit", "reaction", "disappearing", "system", "deleted"]

    /// nil — уведомления по этому сообщению быть не должно.
    /// - Parameters:
    ///   - showsMessageText: настройка «показывать текст в уведомлениях»;
    ///     при false остаются имя отправителя, название группы и аватар.
    ///   - isDeleted: сообщение удалено для всех.
    public static func build(payload: ContentPayload,
                             chat: ChatInfo,
                             sender: SenderInfo,
                             showsMessageText: Bool = true,
                             isDeleted: Bool = false) -> NotificationContent? {
        guard !isDeleted, !silentKinds.contains(payload.kind) else { return nil }
        let name = sender.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let groupTitle = chat.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = name.isEmpty ? (chat.isGroup ? (groupTitle ?? "Группа") : "Msngr") : name
        return NotificationContent(
            title: title,
            subtitle: chat.isGroup ? (groupTitle?.isEmpty == false ? groupTitle : "Группа") : nil,
            body: showsMessageText ? preview(payload) : hiddenTextBody,
            threadIdentifier: chat.chatId)
    }

    /// Тот же билдер для строки сообщения из локальной БД (текст уже расшифрован).
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

    /// Однострочное превью контента: текст или плейсхолдер медиа с подписью.
    public static func preview(_ payload: ContentPayload) -> String {
        let caption = truncate(payload.text ?? "")
        switch payload.kind {
        case "photo": return withCaption("📷 Фото", caption)
        case "video": return withCaption("🎥 Видео", caption)
        case "voice": return withCaption("🎤 Голосовое сообщение", caption)
        case "album": return withCaption("🖼 Альбом", caption)
        case "contact": return withCaption("👤 Контакт", caption)
        case "file":
            let name = payload.media?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            return withCaption("📎 " + (name?.isEmpty == false ? name! : "Файл"), caption)
        default:
            return caption.isEmpty ? hiddenTextBody : caption
        }
    }

    private static func withCaption(_ placeholder: String, _ caption: String) -> String {
        caption.isEmpty ? placeholder : "\(placeholder): \(caption)"
    }

    /// Схлопывает переносы и обрезает по границе слова, добавляя многоточие.
    public static func truncate(_ text: String, limit: Int = textLimit) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard flat.count > limit else { return flat }
        let head = String(flat.prefix(limit))
        // граница слова: последний пробел в отрезанном куске; если слово одно —
        // режем по лимиту, иначе уведомление осталось бы без текста
        if let space = head.lastIndex(of: " ") {
            let word = head[head.startIndex..<space]
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-—"))
            if !word.isEmpty { return word + "…" }
        }
        return head + "…"
    }
}

/// Настройки приватности уведомлений. Хранятся в defaults группы приложения,
/// чтобы их видел и NSE.
public enum NotificationPreferences {
    public static let showsMessageTextKey = "notifications.showsMessageText"

    /// По умолчанию текст показывается.
    public static func showsMessageText(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: showsMessageTextKey) as? Bool ?? true
    }

    public static func setShowsMessageText(_ value: Bool, in defaults: UserDefaults) {
        defaults.set(value, forKey: showsMessageTextKey)
    }
}
