import UIKit
import Combine
import UserNotifications
import GRDB
import MsngrCore

/// The notification hub. The server pushes every content message over APNs
/// while the live WS delivers the same message into the app, so:
/// - with the app active the banner comes from the WS (in-app), and the system
///   push that catches up is dropped in willPresent (dedup by chatId and seq);
/// - in the background the system push shows it (the NSE fills in the decrypted
///   preview); where push is unavailable (simulator, device without a token) the
///   app posts its own local notification off the WS frame;
/// - the icon badge is the unread count the server computed and sent in the
///   push; the app reports the same number once it knows it itself (`BadgeStore`);
/// - reading a chat clears its delivered notifications from the shade.
@MainActor
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationCoordinator()
    /// chatId of the chat on screen; nil on the chat list or any other screen
    var activeChatId: String?
    /// Whether APNs itself delivers the background banner. When false the app
    /// posts its own local notification for as long as the WS lives in the background.
    var apnsAvailable = true

    /// "<chatId>/<seq>" keys whose banner has already been shown (in-app or
    /// system): the WS↔APNs dedup
    private var shownKeys: Set<String> = []
    private var db: DatabaseQueue?
    private var incomingTask: Task<Void, Never>?
    private var reactionTask: Task<Void, Never>?
    private var badgeCancellable: AnyCancellable?

    func setup() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().setNotificationCategories([NotificationActions.messageCategory()])
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
    }

    /// Called after bootstrap, once the database and the engine are ready.
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
        reactionTask?.cancel()
        reactionTask = Task { [weak self] in
            for await ev in engine.reactionStream.subscribe() {
                guard let self else { return }
                await self.handleReactionWS(ev)
            }
        }
    }

    /// Releases the previous session's database and engine: logout deletes the
    /// storage files, so nothing may go on holding references to them.
    func detach() {
        incomingTask?.cancel()
        incomingTask = nil
        reactionTask?.cancel()
        reactionTask = nil
        badgeCancellable = nil
        if let db {
            Task { try? await db.write { dbc in try BadgeStore.applyLocal(dbc, value: 0) } }
        }
        db = nil
        shownKeys.removeAll()
        activeChatId = nil
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().setBadgeCount(0)
    }

    // MARK: - Incoming over WS → in-app banner

    private func handleIncomingWS(_ ev: SyncEngine.IncomingMessage) async {
        let appActive = UIApplication.shared.applicationState == .active
        let key = Message.feedId(chatId: ev.chatId, seq: ev.seq)
        let info = await bannerInfo(chatId: ev.chatId, seq: ev.seq, from: ev.fromUserId)
        let action = NotificationDecision.forIncomingWS(
            appActive: appActive,
            chatOpen: activeChatId == ev.chatId,
            isOwn: ev.isOwn,
            isService: ev.isService,
            muted: info?.muted ?? false,
            alreadyShown: shownKeys.contains(key),
            apnsAvailable: apnsAvailable,
            repliesToMe: info?.repliesToMe ?? false)
        guard action != .none, let info, let content = info.content else { return }
        // the claim on the message is what stops the push about it from showing
        // a second banner; the extension takes the same one
        guard let db, await NotificationBurstStore.claim(db, chatId: ev.chatId,
                                                         seq: ev.seq) else { return }
        shownKeys.insert(key)
        await show(action, content: content, info: info, chatId: ev.chatId, seq: ev.seq)
    }

    /// Shows prepared content. The avatar comes from the cache; a file that is
    /// missing gets downloaded, and the banner waits no longer than that request.
    private func show(_ action: NotificationDecision.WSAction,
                      content: NotificationContent,
                      info: BannerInfo,
                      chatId: String,
                      seq: Int) async {
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
                userInfo: ["chatId": chatId, "seq": seq])
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: Message.feedId(chatId: chatId, seq: seq),
                                      content: built, trigger: nil))
            // the add raced the read-sweep: the avatar fetch above can finish
            // after the read's unread-count emission already swept the shade,
            // and nothing would ever re-check this one — so it checks itself
            dropReadNotifications()
        case .none:
            break
        }
    }

    /// A peer reacted to a message this account authored: the same banner
    /// path as a message, with the reaction line as the body. The frame is
    /// service on the wire, so no push competes for it: the claim only guards
    /// against a repeated announcement.
    private func handleReactionWS(_ ev: SyncEngine.ReactionEvent) async {
        let appActive = UIApplication.shared.applicationState == .active
        let key = Message.feedId(chatId: ev.chatId, seq: ev.seq)
        guard let info = await reactionBannerInfo(ev) else { return }
        let action = NotificationDecision.forIncomingWS(
            appActive: appActive,
            chatOpen: activeChatId == ev.chatId,
            isOwn: false,
            isService: false,
            muted: info.muted,
            alreadyShown: shownKeys.contains(key),
            apnsAvailable: apnsAvailable)
        guard action != .none, let content = info.content else { return }
        guard let db, await NotificationBurstStore.claim(db, chatId: ev.chatId,
                                                         seq: ev.seq) else { return }
        shownKeys.insert(key)
        await show(action, content: content, info: info, chatId: ev.chatId, seq: ev.seq)
    }

    /// Chat and sender for the reaction banner; nil for a request chat still
    /// hiding its content.
    private func reactionBannerInfo(_ ev: SyncEngine.ReactionEvent) async -> BannerInfo? {
        guard let db else { return nil }
        let showsText = NotificationPreferences.showsMessageText(in: AppGroup.defaults)
        return try? await db.read { dbc -> BannerInfo? in
            let chat = try Chat.fetchOne(dbc, key: ev.chatId)
            guard !ChatPrivacy.hidesContent(chat) else { return nil }
            let isGroup = chat?.kind == .group
            let sender = try User.fetchOne(dbc, key: ev.fromUserId)
            let senderInfo = NotificationContentBuilder.SenderInfo(
                userId: ev.fromUserId,
                displayName: sender?.displayName ?? "",
                avatarId: sender?.avatarId)
            var info = BannerInfo(content: nil, sender: senderInfo, isGroup: isGroup,
                                  chatAvatarId: chat?.avatarId, muted: chat?.muted ?? false)
            info.content = NotificationContentBuilder.reactionContent(
                emoji: ev.emoji, targetText: ev.targetText, targetKind: ev.targetKind,
                chat: NotificationContentBuilder.ChatInfo(chatId: ev.chatId, isGroup: isGroup,
                                                          title: chat?.title),
                sender: senderInfo, showsMessageText: showsText)
            return info
        } ?? nil
    }

    struct BannerInfo {
        /// nil when this message must not raise a notification at all
        var content: NotificationContent?
        var sender: NotificationContentBuilder.SenderInfo
        var isGroup: Bool
        var chatAvatarId: String?
        var muted: Bool
        /// the message quotes one of yours: a muted chat still notifies about it
        var repliesToMe: Bool = false
        /// group members other than self: this is how the system tells the conversation is a group one
        var groupMembers: [NotificationContentBuilder.SenderInfo] = []
    }

    /// Assembles the notification content from the local database: chat, sender, message.
    private func bannerInfo(chatId: String, seq: Int, from: String) async -> BannerInfo? {
        guard let db else { return nil }
        let showsText = NotificationPreferences.showsMessageText(in: AppGroup.defaults)
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
            let message = try Message.fetchOne(dbc, sql: "SELECT * FROM message WHERE chatId = ? AND seq = ?",
                                               arguments: [chatId, seq])
            info.repliesToMe = message?.replyTo?.authorId == ownUserId
                || MessageMarkdown.mentionsUser(message?.text ?? "", userId: ownUserId)
            // a request before it is accepted: the sender's name shows, the content does not
            if hidden {
                info.content = NotificationContentBuilder.requestContent(
                    chat: chatInfo, sender: senderInfo)
            } else if let message {
                info.content = NotificationContentBuilder.build(
                    message: message, chat: chatInfo, sender: senderInfo, showsMessageText: showsText)
            }
            return info
        }
    }

    // MARK: - Badge and shade ↔ unreadCount in the database

    /// Reports the count the app arrived at on its own — a chat was read, the
    /// journal caught up — and clears notifications for read messages.
    private func observeUnread(db: DatabaseQueue) {
        badgeCancellable = ValueObservation
            .tracking { dbc in try BadgeStore.localUnread(dbc) }
            .publisher(in: db, scheduling: .async(onQueue: .main))
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] total in
                guard let self else { return }
                Task {
                    let value = (try? await db.write { dbc in
                        try BadgeStore.applyLocal(dbc, value: total)
                    }) ?? total
                    try? await UNUserNotificationCenter.current().setBadgeCount(value)
                }
                self.dropReadNotifications()
            })
    }

    /// Clears the shade of notifications whose messages are already read. The
    /// check goes by (chatId, seq) against the chat's myReadUpTo: the observer
    /// gets the unread count as a snapshot, and going by that count would pull a
    /// just-shown notification before its message even reached the count.
    private func dropReadNotifications() {
        guard let db else { return }
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let items = delivered.compactMap { n -> (id: String, chatId: String, seq: Int)? in
                guard let chatId = n.request.content.userInfo["chatId"] as? String,
                      let seq = n.request.content.userInfo["seq"] as? Int else { return nil }
                return (n.request.identifier, chatId, seq)
            }
            guard !items.isEmpty else { return }
            Task {
                let chatIds = Set(items.map(\.chatId))
                let placeholders = databaseQuestionMarks(count: chatIds.count)
                let readUpTo: [String: Int] = (try? await db.read { dbc in
                    var out: [String: Int] = [:]
                    for row in try Row.fetchAll(dbc, sql: """
                        SELECT id, myReadUpTo FROM chat WHERE id IN (\(placeholders))
                        """, arguments: StatementArguments([String](chatIds))) {
                        out[row["id"]] = row["myReadUpTo"]
                    }
                    return out
                }) ?? [:]
                let ids = items.filter { $0.seq <= (readUpTo[$0.chatId] ?? 0) }.map(\.id)
                if !ids.isEmpty {
                    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
                }
            }
        }
    }

    // MARK: - System pushes (APNs)

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // an APNs push carries a UNPushNotificationTrigger here, our own local one has nil
        let isLocal = notification.request.trigger == nil
        let userInfo = notification.request.content.userInfo
        guard let chatId = userInfo["chatId"] as? String else {
            MsngrLog.notifications.debug("willPresent: no chatId, showing as is")
            return [.banner]
        }
        let seq = userInfo["seq"] as? Int

        // the message's state in the local database: already in over WS, already read
        var messageInDB = false
        var messageRead = false
        var muted = false
        var repliesToMe = false
        if let db {
            let ownUserId = AppState.shared.session?.userId ?? ""
            let state = try? await db.read { dbc -> (Bool, Bool, Bool, Bool) in
                let muted = try Bool.fetchOne(dbc, sql: "SELECT muted FROM chat WHERE id = ?",
                                              arguments: [chatId]) ?? false
                guard let seq else { return (false, false, muted, false) }
                let row = try Row.fetchOne(dbc, sql: """
                    SELECT m.seq AS seq, m.replyTo AS replyTo, m.text AS text,
                           c.myReadUpTo AS readUpTo
                    FROM message m JOIN chat c ON c.id = m.chatId
                    WHERE m.chatId = ? AND m.seq = ?
                    """, arguments: [chatId, seq])
                let inDB = row != nil
                let read = row.map { ($0["seq"] as? Int ?? Int.max) <= ($0["readUpTo"] as Int) } ?? false
                let reply = (row?["replyTo"] as String?).flatMap {
                    try? JSONDecoder().decode(ReplyPreview.self, from: Data($0.utf8))
                }
                let toMe = reply?.authorId == ownUserId
                    || MessageMarkdown.mentionsUser(row?["text"] as String? ?? "", userId: ownUserId)
                return (inDB, read, muted, toMe)
            }
            (messageInDB, messageRead, muted, repliesToMe) = state ?? (false, false, false, false)
        }

        let key = seq.map { Message.feedId(chatId: chatId, seq: $0) }
        let show = NotificationDecision.shouldPresentSystemPush(
            isLocal: isLocal,
            chatOpen: activeChatId == chatId,
            alreadyShown: key.map(shownKeys.contains) ?? false,
            messageInDB: messageInDB,
            messageRead: messageRead,
            muted: muted,
            repliesToMe: repliesToMe)
        MsngrLog.notifications.debug("""
            willPresent chat=\(chatId, privacy: .public) seq=\(seq ?? -1, privacy: .public) \
            local=\(isLocal) open=\(self.activeChatId == chatId) inDB=\(messageInDB) \
            read=\(messageRead) muted=\(muted) -> \(show ? "show" : "suppress", privacy: .public)
            """)
        guard show else { return [] } // the badge arrives as its own number in the push
        if let key { shownKeys.insert(key) }
        return [.banner, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let chatId = response.notification.request.content.userInfo["chatId"] as? String
        let text = (response as? UNTextInputNotificationResponse)?.userText
        switch NotificationActions.route(actionIdentifier: response.actionIdentifier,
                                         chatId: chatId, userText: text) {
        case .open(let chatId):
            NotificationCenter.default.post(name: .openChatRequested, object: chatId)
        case .reply(let chatId, let text):
            await sendReply(text, chatId: chatId)
        case .mute(let chatId):
            await muteChat(chatId)
        case .none:
            break
        }
    }

    // MARK: - Notification actions

    /// A response can launch the app in the background, ahead of bootstrap;
    /// the handler waits for the core rather than dropping the action.
    private func engineWhenReady() async -> SyncEngine? {
        for _ in 0..<40 {
            if let engine = AppState.shared.engine { return engine }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return nil
    }

    /// Quick reply from the banner: the same outbox path as the composer, so it
    /// works offline and retries on its own.
    private func sendReply(_ text: String, chatId: String) async {
        guard let engine = await engineWhenReady() else { return }
        var content = ContentPayload(kind: "text")
        content.text = text
        try? await engine.enqueue(content: content, chatId: chatId)
    }

    /// Mute from the banner: the local row first (the list and the decision
    /// logic read it), then the server flag for pushes.
    private func muteChat(_ chatId: String) async {
        guard await engineWhenReady() != nil, let db = self.db ?? AppState.shared.db else { return }
        try? await db.write { dbc in
            try dbc.execute(sql: "UPDATE chat SET muted = 1, mutedUntil = NULL WHERE id = ?",
                            arguments: [chatId])
        }
        try? await AppState.shared.api?.setChatFlags(chatId, muted: true)
    }
}

extension Notification.Name {
    static let openChatRequested = Notification.Name("openChatRequested")
    /// Esc pressed in the focused composer: the chat screen walks back out.
    static let chatEscapePressed = Notification.Name("chatEscapePressed")
    /// Ctrl+Tab / Cmd+[ ] in the focused composer: userInfo["forward"] is the
    /// direction; the open chat screen answers with `chatSwitchPerform`.
    static let chatSwitchRequested = Notification.Name("chatSwitchRequested")
    /// The resolved switch: userInfo["chatId"] names the chat being left,
    /// userInfo["forward"] the direction; the chat list swaps the open chat
    /// for its neighbour in the current tab.
    static let chatSwitchPerform = Notification.Name("chatSwitchPerform")
}
