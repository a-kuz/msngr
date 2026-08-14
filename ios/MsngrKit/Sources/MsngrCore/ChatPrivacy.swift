import Foundation

/// Заявка на переписку: пока получатель не нажал «Принять», он видит только факт
/// заявки и профиль отправителя. Текст, медиа, превью и счётчики скрыты на всех
/// поверхностях — лента чата, строка чат-листа, in-app баннер, тело пуша, бейдж.
/// После принятия содержимое раскрывается: сообщения уже лежат в локальной БД.
public enum ChatPrivacy {
    /// Текст вместо превью там, где содержимое скрыто.
    public static let requestPlaceholder = "Новая заявка"

    /// Скрыто ли содержимое чата от текущего пользователя.
    public static func hidesContent(isRequest: Bool, iAccepted: Bool) -> Bool {
        isRequest && !iAccepted
    }

    public static func hidesContent(_ chat: Chat?) -> Bool {
        guard let chat else { return false }
        return hidesContent(isRequest: chat.isRequest, iAccepted: chat.iAccepted)
    }

    /// Превью последнего сообщения: у скрытого чата — плашка заявки.
    public static func preview(isRequest: Bool, iAccepted: Bool, content: String?) -> String? {
        hidesContent(isRequest: isRequest, iAccepted: iAccepted) ? requestPlaceholder : content
    }

    /// Счётчик непрочитанного, который можно показать: скрытый чат не раскрывает,
    /// сколько сообщений уже написали.
    public static func visibleUnread(isRequest: Bool, iAccepted: Bool, unreadCount: Int) -> Int {
        hidesContent(isRequest: isRequest, iAccepted: iAccepted) ? 0 : unreadCount
    }
}
