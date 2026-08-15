import UIKit
import Combine
import UserNotifications
import GRDB
import MsngrCore

/// Узел уведомлений. Сервер шлёт APNs-пуш на каждое контентное сообщение,
/// параллельно живой WS доставляет то же сообщение в приложение, поэтому:
/// - при активном приложении баннер о сообщении показывается по WS (in-app),
///   а догнавший системный пуш гасится в willPresent (дедуп по msgId);
/// - в фоне показывает системный пуш (NSE подставляет расшифрованное превью), а
///   когда пуш недоступен (симулятор, устройство без токена) — своё локальное
///   уведомление по WS-фрейму;
/// - бейдж на иконке всегда равен сумме unreadCount по чатам из локальной БД;
/// - при прочтении чата его доставленные уведомления снимаются из шторки.
@MainActor
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationCoordinator()
    /// chatId чата, открытого на экране (nil — чат-лист/другой экран)
    var activeChatId: String?
    /// доставит ли баннер в фоне сам APNs; false — приложение постит своё
    /// локальное уведомление, пока в фоне жив WS
    var apnsAvailable = true

    /// msgId, для которых баннер уже показан (in-app или системный) — дедуп WS↔APNs
    private var shownMsgIds: Set<String> = []
    private var db: DatabaseQueue?
    private var incomingTask: Task<Void, Never>?
    private var badgeCancellable: AnyCancellable?

    func setup() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
    }

    /// Вызывается после bootstrap: БД и движок готовы.
    func attach(db: DatabaseQueue, engine: SyncEngine, ownUserId: String) {
        self.db = db
        observeUnread(db: db)
        if let api = AppState.shared.api {
            Task { await AvatarCache.shared.prefetchAll(db: db, api: api) }
        }
        incomingTask?.cancel()
        incomingTask = Task { [weak self] in
            for await ev in engine.incomingMessageStream.subscribe() {
                guard let self else { return }
                await self.handleIncomingWS(ev)
            }
        }
    }

    /// Отпускает БД и движок прежней сессии: после логаута файлы хранилища
    /// удаляются, держать на них ссылки нельзя.
    func detach() {
        incomingTask?.cancel()
        incomingTask = nil
        badgeCancellable = nil
        db = nil
        shownMsgIds.removeAll()
        activeChatId = nil
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().setBadgeCount(0)
    }

    // MARK: - Входящее по WS → in-app баннер

    private func handleIncomingWS(_ ev: SyncEngine.IncomingMessage) async {
        let appActive = UIApplication.shared.applicationState == .active
        let info = await bannerInfo(chatId: ev.chatId, msgId: ev.msgId, from: ev.fromUserId)
        let action = NotificationDecision.forIncomingWS(
            appActive: appActive,
            chatOpen: activeChatId == ev.chatId,
            isOwn: ev.isOwn,
            isService: ev.isService,
            muted: info?.muted ?? false,
            alreadyShown: shownMsgIds.contains(ev.msgId),
            apnsAvailable: apnsAvailable)
        guard action != .none, let info, let content = info.content else { return }
        shownMsgIds.insert(ev.msgId)
        await show(action, content: content, info: info, chatId: ev.chatId, msgId: ev.msgId)
    }

    /// Показывает готовый контент: аватар подтягивается из кэша (при отсутствии
    /// файла — качается, но показ не ждёт больше, чем занимает запрос).
    private func show(_ action: NotificationDecision.WSAction,
                      content: NotificationContent,
                      info: BannerInfo,
                      chatId: String,
                      msgId: String) async {
        let api = AppState.shared.api
        let avatar = await AvatarCache.shared.ensure(info.sender.avatarId, api: api)
        switch action {
        case .inAppBanner:
            InAppBannerPresenter.show(title: content.title, subtitle: content.subtitle,
                                      body: content.body, avatar: avatar, chatId: chatId)
        case .localNotification:
            let groupAvatar = info.isGroup
                ? await AvatarCache.shared.ensure(info.chatAvatarId, api: api)
                : nil
            let built = CommunicationNotification.content(
                content,
                sender: info.sender,
                ownUserId: AppState.shared.session?.userId ?? "",
                isGroup: info.isGroup,
                avatarFile: avatar,
                groupMembers: info.groupMembers,
                groupAvatarFile: groupAvatar,
                userInfo: ["chatId": chatId, "msgId": msgId])
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: msgId, content: built, trigger: nil))
        case .none:
            break
        }
    }

    struct BannerInfo {
        /// nil — уведомления по этому сообщению быть не должно
        var content: NotificationContent?
        var sender: NotificationContentBuilder.SenderInfo
        var isGroup: Bool
        var chatAvatarId: String?
        var muted: Bool
        /// участники группы кроме себя — по ним система понимает, что разговор групповой
        var groupMembers: [NotificationContentBuilder.SenderInfo] = []
    }

    /// Собирает контент уведомления из локальной БД: чат, отправитель, сообщение.
    private func bannerInfo(chatId: String, msgId: String, from: String) async -> BannerInfo? {
        guard let db else { return nil }
        let showsText = NotificationPreferences.showsMessageText(in: .standard)
        let ownUserId = AppState.shared.session?.userId ?? ""
        return try? await db.read { dbc -> BannerInfo in
            let chat = try Chat.fetchOne(dbc, key: chatId)
            let hidden = ChatPrivacy.hidesContent(chat)
            let isGroup = chat?.kind == .group
            let sender = try User.fetchOne(dbc, key: from)
            let senderInfo = NotificationContentBuilder.SenderInfo(
                userId: from,
                displayName: sender?.displayName ?? "",
                avatarId: sender?.avatarId)
            let chatInfo = NotificationContentBuilder.ChatInfo(
                chatId: chatId, isGroup: isGroup, title: chat?.title)
            var info = BannerInfo(content: nil, sender: senderInfo, isGroup: isGroup,
                                  chatAvatarId: chat?.avatarId, muted: chat?.muted ?? false)
            if isGroup {
                info.groupMembers = try Row.fetchAll(dbc, sql: """
                    SELECT m.userId AS id, u.displayName AS name
                    FROM member m LEFT JOIN user u ON u.id = m.userId
                    WHERE m.chatId = ? AND m.userId <> ?
                    """, arguments: [chatId, ownUserId])
                    .map { NotificationContentBuilder.SenderInfo(userId: $0["id"],
                                                                 displayName: $0["name"] ?? "") }
            }
            // заявка до принятия: имя отправителя показываем, содержимое — нет
            if hidden {
                info.content = NotificationContentBuilder.requestContent(
                    chat: chatInfo, sender: senderInfo)
            } else if let m = try Message.fetchOne(dbc, sql: "SELECT * FROM message WHERE msgId = ?",
                                                   arguments: [msgId]) {
                info.content = NotificationContentBuilder.build(
                    message: m, chat: chatInfo, sender: senderInfo, showsMessageText: showsText)
            }
            return info
        }
    }

    // MARK: - Бейдж и шторка ↔ unreadCount в БД

    /// Единый источник истины — chat.unreadCount: бейдж — сумма по чатам
    /// (заявка до принятия в него не входит: счётчик выдал бы, сколько написали);
    /// прочитанные сообщения снимаются из шторки по msgId.
    private func observeUnread(db: DatabaseQueue) {
        badgeCancellable = ValueObservation
            .tracking { dbc in
                try Row.fetchAll(dbc, sql: "SELECT unreadCount, isRequest, iAccepted FROM chat")
                    .reduce(0) { sum, row in
                        sum + ChatPrivacy.visibleUnread(isRequest: row["isRequest"],
                                                        iAccepted: row["iAccepted"],
                                                        unreadCount: row["unreadCount"])
                    }
            }
            .publisher(in: db, scheduling: .async(onQueue: .main))
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] total in
                UNUserNotificationCenter.current().setBadgeCount(total)
                self?.dropReadNotifications()
            })
    }

    /// Снимает из шторки уведомления о сообщениях, которые уже прочитаны.
    /// Сверка идёт по msgId с myReadUpTo чата: счётчик непрочитанных приходит
    /// наблюдателю снимком, и по нему только что показанное уведомление
    /// снималось бы раньше, чем сообщение успело в этот счётчик попасть.
    private func dropReadNotifications() {
        guard let db else { return }
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let items = delivered.compactMap { n -> (id: String, msgId: String)? in
                guard let msgId = n.request.content.userInfo["msgId"] as? String else { return nil }
                return (n.request.identifier, msgId)
            }
            guard !items.isEmpty else { return }
            Task {
                let msgIds = items.map(\.msgId)
                let placeholders = databaseQuestionMarks(count: msgIds.count)
                let read = (try? await db.read { dbc in
                    try String.fetchSet(dbc, sql: """
                        SELECT m.msgId FROM message m JOIN chat c ON c.id = m.chatId
                        WHERE m.msgId IN (\(placeholders)) AND m.seq <= c.myReadUpTo
                        """, arguments: StatementArguments(msgIds))
                }) ?? []
                let ids = items.filter { read.contains($0.msgId) }.map(\.id)
                if !ids.isEmpty {
                    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
                }
            }
        }
    }

    // MARK: - Системные пуши (APNs)

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // у APNs-пуша здесь UNPushNotificationTrigger, у своего локального — nil
        let isLocal = notification.request.trigger == nil
        let userInfo = notification.request.content.userInfo
        guard let chatId = userInfo["chatId"] as? String else { return [.banner] }
        let msgId = userInfo["msgId"] as? String

        // состояние сообщения в локальной БД: получено ли уже по WS, прочитано ли
        var messageInDB = false
        var messageRead = false
        var muted = false
        if let db {
            let state = try? await db.read { dbc -> (Bool, Bool, Bool) in
                let muted = try Bool.fetchOne(dbc, sql: "SELECT muted FROM chat WHERE id = ?",
                                              arguments: [chatId]) ?? false
                guard let msgId else { return (false, false, muted) }
                let row = try Row.fetchOne(dbc, sql: """
                    SELECT m.seq AS seq, c.myReadUpTo AS readUpTo
                    FROM message m JOIN chat c ON c.id = m.chatId WHERE m.msgId = ?
                    """, arguments: [msgId])
                let inDB = row != nil
                let read = row.map { ($0["seq"] as? Int ?? Int.max) <= ($0["readUpTo"] as Int) } ?? false
                return (inDB, read, muted)
            }
            (messageInDB, messageRead, muted) = state ?? (false, false, false)
        }

        let show = NotificationDecision.shouldPresentSystemPush(
            isLocal: isLocal,
            chatOpen: activeChatId == chatId,
            alreadyShown: msgId.map(shownMsgIds.contains) ?? false,
            messageInDB: messageInDB,
            messageRead: messageRead,
            muted: muted)
        guard show else { return [] } // бейдж ведёт локальный наблюдатель БД
        if let msgId { shownMsgIds.insert(msgId) }
        return [.banner, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        // tap по пушу → открыть чат
        if let chatId = response.notification.request.content.userInfo["chatId"] as? String {
            NotificationCenter.default.post(name: .openChatRequested, object: chatId)
        }
    }
}

extension Notification.Name {
    static let openChatRequested = Notification.Name("openChatRequested")
}
