import Foundation

/// Why an outgoing message was never sent.
///
/// The codes are machine-readable: some arrive from the server in an
/// `{t:"error", error}` frame (see docs/protocol.md), the rest are set by the client
/// when the message never reached the server. They are stored in `message.failReason`;
/// the user-facing wording sits next to them so a code and its text change together.
public enum SendFailure {
    /// Server refused: the recipient is on our block list.
    public static let blocked = "blocked"
    /// Server refused: we are no longer a member of the chat.
    public static let notMember = "not_member"
    /// Server refused without saying why.
    public static let sendFailed = "send_failed"
    /// Client never sent it: the peer's identity key changed and has not been trusted yet (TOFU).
    public static let identityChanged = "identity_changed"
    /// Client never sent it: out of attempts.
    public static let tooManyAttempts = "too_many_attempts"

    /// One title for every reason; what matters to the user is the fact, not the code.
    public static let title = "Сообщение не доставлено"

    /// The explanation shown to the user. An unknown code (a server running ahead of us)
    /// still gets wording rather than an empty string.
    public static func explanation(_ code: String?) -> String {
        switch code {
        case blocked:
            return "Вы заблокировали этого пользователя. Снимите блокировку, чтобы писать ему."
        case notMember:
            return "Вы больше не участник этого чата."
        case identityChanged:
            return "Ключ собеседника сменился. Подтвердите новый ключ, чтобы отправить сообщение."
        case tooManyAttempts:
            return "Не удалось связаться с сервером. Проверьте соединение и отправьте сообщение заново."
        default:
            return "Сервер отклонил сообщение. Отправьте его заново или удалите."
        }
    }
}
