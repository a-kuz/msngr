import Foundation

/// Запрос «показать это сообщение в ленте».
///
/// Открытый экран чата берёт запрос уведомлением. Из поиска чат ещё только
/// открывается, слушать уведомление в этот момент некому — поэтому запрос
/// заодно кладётся сюда, и экран забирает его, когда появится.
struct MessageJump {
    let chatId: String
    let msgId: String

    private(set) static var pending: MessageJump?

    static func request(chatId: String, msgId: String) {
        let jump = MessageJump(chatId: chatId, msgId: msgId)
        pending = jump
        NotificationCenter.default.post(name: .showMessageInChat, object: jump)
    }

    /// Отдаёт запрос этому чату и снимает его: перехода добиваются один раз.
    static func take(chatId: String) -> MessageJump? {
        guard let jump = pending, jump.chatId == chatId else { return nil }
        pending = nil
        return jump
    }
}

extension Notification.Name {
    static let showMessageInChat = Notification.Name("showMessageInChat")
}
