import Foundation

/// Чистая логика «показывать ли уведомление». Сервер шлёт APNs-пуш немедленно
/// на каждое контентное сообщение, даже при живом WS, поэтому при активном
/// приложении одно сообщение приходит дважды: WS-фрейм и системный пуш через
/// ~150–500 мс. Дедуп между ними — здесь.
enum NotificationDecision {
    /// Реакция на контентное сообщение, принятое по WS.
    enum WSAction: Equatable {
        /// ничего не показывать
        case none
        /// верхний in-app баннер (только активное приложение, чат не открыт)
        case inAppBanner
    }

    /// Сообщение пришло по WS.
    /// В фоне ничего не показываем: системный APNs-пуш придёт сам,
    /// локальная нотификация дала бы дубль.
    static func forIncomingWS(appActive: Bool, chatOpen: Bool, isOwn: Bool,
                              isService: Bool, muted: Bool, alreadyShown: Bool) -> WSAction {
        if isOwn || isService || muted || alreadyShown { return .none }
        guard appActive, !chatOpen else { return .none }
        return .inAppBanner
    }

    /// Показывать ли системный пуш, догнавший активное приложение (willPresent).
    /// - messageInDB: сообщение уже принято по WS (строка в БД) — баннер был бы дублем
    /// - alreadyShown: для этого msgId уже показан in-app баннер или системный пуш
    /// - messageRead: сообщение уже прочитано (seq <= myReadUpTo)
    static func shouldPresentSystemPush(chatOpen: Bool, alreadyShown: Bool,
                                        messageInDB: Bool, messageRead: Bool,
                                        muted: Bool) -> Bool {
        !(chatOpen || alreadyShown || messageInDB || messageRead || muted)
    }
}
