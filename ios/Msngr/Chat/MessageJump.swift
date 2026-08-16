import Foundation

/// A request to show this message in the feed.
///
/// A chat screen that is already open picks the request up from a notification. Coming
/// from search the chat is only about to open and there is nobody to hear that
/// notification, so the request is also parked here and the screen takes it on appearing.
struct MessageJump {
    let chatId: String
    let msgId: String

    private(set) static var pending: MessageJump?

    static func request(chatId: String, msgId: String) {
        let jump = MessageJump(chatId: chatId, msgId: msgId)
        pending = jump
        NotificationCenter.default.post(name: .showMessageInChat, object: jump)
    }

    /// Hands the request to this chat and clears it: the jump is made once.
    static func take(chatId: String) -> MessageJump? {
        guard let jump = pending, jump.chatId == chatId else { return nil }
        pending = nil
        return jump
    }
}

extension Notification.Name {
    static let showMessageInChat = Notification.Name("showMessageInChat")
}
