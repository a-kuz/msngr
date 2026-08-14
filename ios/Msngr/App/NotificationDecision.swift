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
        /// системный баннер, который приложение постит само
        case localNotification
    }

    /// Сообщение пришло по WS.
    /// В фоне баннер показывает системный APNs-пуш, локальная нотификация дала
    /// бы дубль. Когда пуш прийти не может (симулятор, устройство без
    /// зарегистрированного токена), а WS ещё жив — баннер постит приложение.
    static func forIncomingWS(appActive: Bool, chatOpen: Bool, isOwn: Bool,
                              isService: Bool, muted: Bool, alreadyShown: Bool,
                              apnsAvailable: Bool = true) -> WSAction {
        if isOwn || isService || muted || alreadyShown { return .none }
        guard appActive else { return apnsAvailable ? .none : .localNotification }
        return chatOpen ? .none : .inAppBanner
    }

    /// Показывать ли уведомление, о котором система спросила делегата (willPresent).
    /// - isLocal: уведомление поставило само приложение по WS-фрейму. Оно уже
    ///   прошло все проверки при постановке, а его msgId лежит в alreadyShown,
    ///   и общий дедуп погасил бы его же.
    /// - messageInDB: сообщение уже принято по WS (строка в БД) — баннер был бы дублем
    /// - alreadyShown: для этого msgId уже показан in-app баннер или системный пуш
    /// - messageRead: сообщение уже прочитано (seq <= myReadUpTo)
    static func shouldPresentSystemPush(isLocal: Bool = false,
                                        chatOpen: Bool, alreadyShown: Bool,
                                        messageInDB: Bool, messageRead: Bool,
                                        muted: Bool) -> Bool {
        if isLocal { return true }
        return !(chatOpen || alreadyShown || messageInDB || messageRead || muted)
    }
}
