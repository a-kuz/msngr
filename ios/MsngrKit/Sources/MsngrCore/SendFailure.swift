import Foundation

/// Причины, по которым исходящее сообщение осталось неотправленным.
///
/// Коды — машиночитаемые: часть приходит с сервера фреймом `{t:"error", error}`
/// (см. docs/protocol.md), часть ставит сам клиент, когда до сервера не дошло.
/// Хранятся в колонке `message.failReason`; тексты для пользователя лежат рядом,
/// чтобы код и его формулировка правились одним изменением.
public enum SendFailure {
    /// Сервер отказал: получатель в нашем чёрном списке.
    public static let blocked = "blocked"
    /// Сервер отказал: мы больше не участник чата.
    public static let notMember = "not_member"
    /// Сервер отказал без уточнения причины.
    public static let sendFailed = "send_failed"
    /// Клиент не отправил: identity-ключ собеседника сменился и ещё не принят (TOFU).
    public static let identityChanged = "identity_changed"
    /// Клиент не отправил: попытки исчерпаны.
    public static let tooManyAttempts = "too_many_attempts"

    /// Заголовок для любой причины: пользователю важен факт, а не код.
    public static let title = "Сообщение не доставлено"

    /// Объяснение причины для пользователя. Неизвестный код (сервер ушёл вперёд)
    /// даёт общую формулировку, а не пустую строку.
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
