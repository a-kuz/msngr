import UIKit
import Combine
import UserNotifications
import GRDB
import MsngrCore

/// Узел уведомлений. Сервер шлёт APNs-пуш на каждое контентное сообщение,
/// параллельно живой WS доставляет то же сообщение в приложение, поэтому:
/// - при активном приложении баннер о сообщении показывается по WS (in-app),
///   а догнавший системный пуш гасится в willPresent (дедуп по msgId);
/// - в фоне показывает только системный пуш (NSE подставляет расшифрованное превью);
/// - бейдж на иконке всегда равен сумме unreadCount по чатам из локальной БД;
/// - при прочтении чата его доставленные уведомления снимаются из шторки.
@MainActor
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationCoordinator()
    /// chatId чата, открытого на экране (nil — чат-лист/другой экран)
    var activeChatId: String?

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
        incomingTask?.cancel()
        incomingTask = Task { [weak self] in
            for await ev in engine.incomingMessageStream.subscribe() {
                guard let self else { return }
                await self.handleIncomingWS(ev)
            }
        }
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
            muted: info.muted,
            alreadyShown: shownMsgIds.contains(ev.msgId))
        guard action == .inAppBanner else { return }
        shownMsgIds.insert(ev.msgId)
        InAppBannerPresenter.show(title: info.title, body: info.preview, chatId: ev.chatId)
    }

    private struct BannerInfo {
        var title = "Msngr"
        var preview = "Новое сообщение"
        var muted = false
    }

    /// Заголовок чата и расшифрованное превью из локальной БД.
    private func bannerInfo(chatId: String, msgId: String, from: String) async -> BannerInfo {
        guard let db else { return BannerInfo() }
        let ownId = AppState.shared.session?.userId ?? ""
        return (try? await db.read { dbc -> BannerInfo in
            var info = BannerInfo()
            let chat = try Chat.fetchOne(dbc, key: chatId)
            info.muted = chat?.muted ?? false
            let hidden = ChatPrivacy.hidesContent(chat)
            let isGroup = chat?.kind == .group
            if isGroup {
                info.title = chat?.title ?? "Группа"
            } else if let peerId = try String.fetchOne(
                dbc, sql: "SELECT userId FROM member WHERE chatId = ? AND userId != ?",
                arguments: [chatId, ownId]),
                let peer = try User.fetchOne(dbc, key: peerId) {
                info.title = peer.displayName
            }
            // заявка до принятия: имя отправителя показываем, содержимое — нет
            if hidden {
                info.preview = ChatPrivacy.requestPlaceholder
            } else if let m = try Message.fetchOne(dbc, sql: "SELECT * FROM message WHERE msgId = ?",
                                                   arguments: [msgId]) {
                let author = isGroup
                    ? try String.fetchOne(dbc, sql: "SELECT displayName FROM user WHERE id = ?",
                                          arguments: [from])
                    : nil
                info.preview = Self.preview(m, authorName: author)
            }
            return info
        }) ?? BannerInfo()
    }

    /// Однострочное превью сообщения (текст уже расшифрован движком в БД).
    nonisolated static func preview(_ m: Message, authorName: String?) -> String {
        let body: String
        switch m.kind {
        case .photo: body = "📷 Фото"
        case .video: body = "🎥 Видео"
        case .voice: body = "🎤 Голосовое сообщение"
        case .file: body = "📎 " + (m.media?.name ?? "Файл")
        case .album: body = "🖼 Альбом"
        case .system: body = "Новое сообщение"
        default: body = m.text ?? "Новое сообщение"
        }
        if let authorName { return "\(authorName): \(body)" }
        return body
    }

    // MARK: - Бейдж и шторка ↔ unreadCount в БД

    /// Единый источник истины — chat.unreadCount: бейдж — сумма по чатам
    /// (заявка до принятия в него не входит: счётчик выдал бы, сколько написали);
    /// доставленные уведомления прочитанных чатов снимаются из шторки.
    private func observeUnread(db: DatabaseQueue) {
        badgeCancellable = ValueObservation
            .tracking { dbc in
                try Row.fetchAll(dbc, sql: "SELECT id, unreadCount, isRequest, iAccepted FROM chat")
                    .map { (id: $0["id"] as String, unread: $0["unreadCount"] as Int,
                            visible: ChatPrivacy.visibleUnread(isRequest: $0["isRequest"],
                                                               iAccepted: $0["iAccepted"],
                                                               unreadCount: $0["unreadCount"])) }
            }
            .publisher(in: db, scheduling: .async(onQueue: .main))
            .sink(receiveCompletion: { _ in }, receiveValue: { rows in
                let total = rows.reduce(0) { $0 + $1.visible }
                let readChatIds = Set(rows.filter { $0.unread == 0 }.map(\.id))
                let center = UNUserNotificationCenter.current()
                center.setBadgeCount(total)
                guard !readChatIds.isEmpty else { return }
                center.getDeliveredNotifications { delivered in
                    let ids = delivered
                        .filter { n in
                            let content = n.request.content
                            let chatId = (content.userInfo["chatId"] as? String)
                                ?? (content.threadIdentifier.isEmpty ? nil : content.threadIdentifier)
                            return chatId.map(readChatIds.contains) ?? false
                        }
                        .map(\.request.identifier)
                    if !ids.isEmpty {
                        center.removeDeliveredNotifications(withIdentifiers: ids)
                    }
                }
            })
    }

    // MARK: - Системные пуши (APNs)

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
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
