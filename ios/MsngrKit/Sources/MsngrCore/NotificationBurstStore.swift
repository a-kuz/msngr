import Foundation
import GRDB

/// The database side of a burst of pushes: what the device already knows about
/// the messages, who claims the right to present each of them, and how far the
/// chats went while the device was offline.
public enum NotificationBurstStore {
    /// How long a claim is kept. It only guards against showing a message
    /// twice, and a push for a week old message no longer arrives.
    public static let claimTTL: TimeInterval = 7 * 24 * 3600

    // MARK: - Claim

    /// Takes the right to present a message. False means somebody already has
    /// it — the other extension handler, or the app that showed it over the
    /// socket. The insert is the whole decision, so parallel writers cannot
    /// both win.
    @discardableResult
    public static func claim(_ dbc: GRDB.Database, chatId: String, seq: Int,
                             now: Double = Date().timeIntervalSince1970) throws -> Bool {
        try dbc.execute(sql: """
            INSERT OR IGNORE INTO notificationShown (chatId, seq, shownAt)
            VALUES (?,?,?)
            """, arguments: [chatId, seq, now])
        return dbc.changesCount > 0
    }

    /// Same claim from outside a transaction of its own.
    @discardableResult
    public static func claim(_ db: DatabaseQueue, chatId: String, seq: Int,
                             now: Double = Date().timeIntervalSince1970) async -> Bool {
        (try? await db.write { dbc in
            try claim(dbc, chatId: chatId, seq: seq, now: now)
        }) ?? false
    }

    public static func isShown(_ dbc: GRDB.Database, chatId: String, seq: Int) throws -> Bool {
        try Bool.fetchOne(dbc, sql: "SELECT EXISTS(SELECT 1 FROM notificationShown WHERE chatId = ? AND seq = ?)",
                          arguments: [chatId, seq]) ?? false
    }

    // MARK: - Plan

    /// Orders a batch of pushes, decides which of them produce a banner and
    /// records how far the chats went. Runs in one transaction: the claim of
    /// every shown message and the chat cursor move together, so a handler
    /// entered in parallel sees the finished result and not a half of it.
    public static func resolve(db: DatabaseQueue, items: [BurstItem],
                               showsMessageText: Bool,
                               envelopes: [String: PushEnvelope] = [:],
                               writer: PushMessageWriter? = nil,
                               journal: NotificationJournal? = nil,
                               ownUserId: String? = nil,
                               now: Double = Date().timeIntervalSince1970) throws -> BurstPlan {
        let ownUserId = ownUserId ?? writer?.ownUserId
        return try db.write { dbc -> BurstPlan in
            // The messages the pushes carry are written first: everything below
            // — the banner text, the seqs a chat is missing, the count of what
            // is unread — is read from the database, and this is what puts them
            // there. One transaction covers the ratchet step and the row it
            // produced, so an extension the system kills leaves neither behind.
            // what each envelope turned out to hold: a reaction has no row of
            // its own, so its banner is built from the payload
            var applied: [String: ContentPayload] = [:]
            if let writer, !envelopes.isEmpty {
                for item in items.sorted(by: { $0.seq < $1.seq }) {
                    guard let envelope = envelopes[item.key] else { continue }
                    var written = writer.writeApplied(dbc, item: item, envelope: envelope, now: now)
                    // the first message of a request: the chat is not on this
                    // device yet, and the push names its author, so the chat is
                    // written as the request it is and the message goes into it
                    if written.outcome == .unknownChat, let name = envelope.fromName,
                       try adoptRequestChat(dbc, chatId: item.chatId, from: envelope.fromUserId,
                                            fromName: name, ownUserId: writer.ownUserId,
                                            sentAt: item.sentAt) {
                        written = writer.writeApplied(dbc, item: item, envelope: envelope, now: now)
                    }
                    if let payload = written.applied { applied[item.key] = payload }
                    journal?.record(.stored, chatId: item.chatId, seq: item.seq,
                                    detail: written.outcome.rawValue)
                }
                for chatId in Set(items.map(\.chatId)) {
                    try PushMessageWriter.extendSyncedPrefix(dbc, chatId: chatId)
                }
            }
            var state: [String: BurstItemState] = [:]
            var baseline: [String: ChatBurstBaseline] = [:]
            var chats: [String: Chat] = [:]

            for chatId in Set(items.map(\.chatId)) {
                let chat = try Chat.fetchOne(dbc, key: chatId)
                chats[chatId] = chat
                let lower = (chat?.lastSeq ?? 0) + 1
                let known = try Int.fetchAll(dbc, sql: """
                    SELECT seq FROM message WHERE chatId = ? AND seq IS NOT NULL AND seq >= ?
                    """, arguments: [chatId, lower])
                baseline[chatId] = ChatBurstBaseline(lastSeq: chat?.lastSeq ?? 0,
                                                     knownSeqs: Set(known))
            }

            for item in items {
                let chat = chats[item.chatId]
                // a message that speaks to this user gets through a muted chat
                let toMe = try ownUserId.map {
                    try addressedToMe(dbc, chatId: item.chatId, seq: item.seq, ownUserId: $0)
                } ?? false
                state[item.key] = BurstItemState(
                    alreadyShown: try isShown(dbc, chatId: item.chatId, seq: item.seq),
                    read: item.seq <= (chat?.myReadUpTo ?? 0),
                    muted: !toMe && MuteState.isMuted(muted: chat?.muted ?? false,
                                                      mutedUntil: chat?.mutedUntil, now: now))
            }

            var plan = NotificationBurstPlanner.plan(items: items, state: state, baseline: baseline)

            // the burst names seqs the chat reached: moving the cursor is what
            // makes HistoryWindow.openGaps hand the hole to the app
            for (chatId, chat) in chats where chat != nil {
                guard let top = items.filter({ $0.chatId == chatId }).map(\.seq).max() else { continue }
                try dbc.execute(sql: """
                    UPDATE chat SET lastSeq = MAX(lastSeq, ?),
                                    unreadCount = MAX(0, MAX(lastSeq, ?) - myReadUpTo)
                    WHERE id = ?
                    """, arguments: [top, top, chatId])
            }

            // The push is the message arriving at the device, so the author is
            // owed his second tick now and not when the app is next opened. The
            // extension posts it right after this transaction; the row is what
            // survives being killed in between, and the app sends it on its
            // next connection. An unaccepted request answers nothing — its
            // recipient is invisible to whoever wrote.
            for (chatId, chat) in chats where !chat.isRequest {
                guard let top = items.filter({ $0.chatId == chatId }).map(\.seq).max() else { continue }
                try DeliveryReceipts.record(dbc, chatId: chatId, upToSeq: top, now: now)
            }

            for i in plan.steps.indices {
                guard plan.steps[i].outcome == .show else { continue }
                let item = plan.steps[i].item
                guard try claim(dbc, chatId: item.chatId, seq: item.seq, now: now) else {
                    plan.steps[i].outcome = .skip(.duplicate)
                    continue
                }
                switch try content(dbc, item: item, chat: chats[item.chatId],
                                   showsMessageText: showsMessageText,
                                   applied: applied[item.key],
                                   appliedFrom: envelopes[item.key]?.fromUserId,
                                   ownUserId: ownUserId) {
                case .built(let built): plan.steps[i].content = built
                case .fromPush: break
                case .silent: plan.steps[i].outcome = .skip(.silent)
                }
            }

            try dbc.execute(sql: "DELETE FROM notificationShown WHERE shownAt < ?",
                            arguments: [now - claimTTL])
            return plan
        }
    }

    /// What the banner of a push says.
    enum BurstContent: Equatable {
        /// Built from the message this device stores.
        case built(NotificationContent)
        /// The message is not stored here yet: the push keeps the text it
        /// arrived with, which is neutral and never wrong.
        case fromPush
        /// The stored message carries nothing to announce.
        case silent
    }

    /// - Parameters:
    ///   - applied: what the push's envelope held, when the burst wrote it; a
    ///     reaction leaves no row and is announced from this alone.
    ///   - appliedFrom: the author of that envelope.
    ///   - ownUserId: this user, who is the only one a reaction is announced to.
    static func content(_ dbc: GRDB.Database, item: BurstItem, chat: Chat?,
                        showsMessageText: Bool,
                        applied: ContentPayload? = nil, appliedFrom: String? = nil,
                        ownUserId: String? = nil) throws -> BurstContent {
        guard let chat else { return .fromPush }
        if let applied, applied.kind == "reaction" {
            return try reactionContent(dbc, applied, from: appliedFrom, chat: chat,
                                       ownUserId: ownUserId, showsMessageText: showsMessageText)
        }
        let message = try Message.fetchOne(dbc, sql: "SELECT * FROM message WHERE chatId = ? AND seq = ?",
                                           arguments: [item.chatId, item.seq])
        let senderId = message?.fromUserId
        let sender = try senderId.flatMap { try User.fetchOne(dbc, key: $0) }
            .map { try ContactBookName.applied(dbc, to: $0) }
        let senderInfo = NotificationContentBuilder.SenderInfo(
            userId: senderId ?? "",
            displayName: sender?.displayName ?? "",
            avatarId: sender?.avatarId)
        let chatInfo = NotificationContentBuilder.ChatInfo(
            chatId: chat.id, isGroup: chat.kind == .group, title: chat.title, avatarId: chat.avatarId)
        if ChatPrivacy.hidesContent(chat) {
            var built = NotificationContentBuilder.requestContent(chat: chatInfo, sender: senderInfo)
            if chatInfo.isGroup { built.groupMembers = try groupMembers(dbc, chatId: chat.id) }
            return .built(built)
        }
        guard let message else { return .fromPush }
        guard var built = NotificationContentBuilder.build(
            message: message, chat: chatInfo, sender: senderInfo,
            showsMessageText: showsMessageText) else { return .silent }
        if chatInfo.isGroup { built.groupMembers = try groupMembers(dbc, chatId: chat.id) }
        if let ownUserId {
            built.addressedToMe = message.replyTo?.authorId == ownUserId
                || MessageMarkdown.mentionsUser(message.text ?? "", userId: ownUserId)
        }
        return .built(built)
    }

    /// True when the stored message speaks to this user: a reply to a message
    /// of theirs, or a mention of them in the text.
    static func addressedToMe(_ dbc: GRDB.Database, chatId: String, seq: Int,
                              ownUserId: String) throws -> Bool {
        guard let row = try Row.fetchOne(dbc, sql: "SELECT replyTo, text FROM message WHERE chatId = ? AND seq = ?",
                                         arguments: [chatId, seq]) else { return false }
        let reply = (row["replyTo"] as String?).flatMap {
            try? JSONDecoder().decode(ReplyPreview.self, from: Data($0.utf8))
        }
        return reply?.authorId == ownUserId
            || MessageMarkdown.mentionsUser(row["text"] as String? ?? "", userId: ownUserId)
    }

    /// The banner of a reaction that arrived by push: only for a reaction set
    /// (not cleared) on a message this user wrote, and only while the chat
    /// shows its content. Anything else is silent.
    static func reactionContent(_ dbc: GRDB.Database, _ payload: ContentPayload, from: String?,
                                chat: Chat, ownUserId: String?,
                                showsMessageText: Bool) throws -> BurstContent {
        guard let emoji = payload.emoji, let targetSeq = payload.targetSeq,
              let from, let ownUserId, !ChatPrivacy.hidesContent(chat) else { return .silent }
        guard let target = try Row.fetchOne(dbc, sql: """
                  SELECT fromUserId, text, kind FROM message WHERE chatId = ? AND seq = ?
                  """, arguments: [chat.id, targetSeq]),
              target["fromUserId"] as String == ownUserId else { return .silent }
        let sender = try User.fetchOne(dbc, key: from).map { try ContactBookName.applied(dbc, to: $0) }
        let senderInfo = NotificationContentBuilder.SenderInfo(
            userId: from, displayName: sender?.displayName ?? "", avatarId: sender?.avatarId)
        let chatInfo = NotificationContentBuilder.ChatInfo(
            chatId: chat.id, isGroup: chat.kind == .group, title: chat.title, avatarId: chat.avatarId)
        var built = NotificationContentBuilder.reactionContent(
            emoji: emoji, targetText: target["text"], targetKind: target["kind"],
            chat: chatInfo, sender: senderInfo, showsMessageText: showsMessageText)
        if chatInfo.isGroup { built.groupMembers = try groupMembers(dbc, chatId: chat.id) }
        return .built(built)
    }

    /// Writes a direct chat this device has never seen as the request it is:
    /// the author, named as the push named them, and this user as the member
    /// who has not accepted yet. The chat's state proper arrives with the app's
    /// next connection and lands on top of this row. False when the chat is not
    /// a direct chat between this user and the author, in which case nothing is
    /// written.
    @discardableResult
    public static func adoptRequestChat(_ dbc: GRDB.Database, chatId: String, from: String,
                                        fromName: String, ownUserId: String,
                                        sentAt: Double) throws -> Bool {
        let parts = chatId.split(separator: ":").map(String.init)
        guard parts.count == 3, parts[0] == ChatKind.direct.rawValue,
              Set(parts[1...]) == [from, ownUserId], from != ownUserId else { return false }
        try dbc.execute(
            sql: """
            INSERT INTO user (id, username, displayName, bio, avatarId, botOwner, botCommands)
            VALUES (?,?,?,?,?,?,?)
            ON CONFLICT(id) DO NOTHING
            """,
            arguments: [from, "", fromName, nil, nil, nil, nil])
        let createdAt = sentAt > 0 ? sentAt / 1000 : Date().timeIntervalSince1970
        let state = ChatStateDTO(
            chatId: chatId, kind: ChatKind.direct.rawValue, title: nil, avatarId: nil,
            description: nil, sendPolicy: nil, invitePolicy: nil, createdBy: from,
            createdAt: createdAt, plaintext: nil,
            members: [.init(userId: from, role: "member", joinedAt: createdAt, accepted: true),
                      .init(userId: ownUserId, role: "member", joinedAt: createdAt, accepted: false)],
            pinnedSeqs: nil, lastSeq: 0, readMarks: [:], deliveredMarks: [:])
        try SyncEngine.upsertChatState(dbc, state, ownUserId: ownUserId, flags: nil)
        return true
    }

    /// Every member of a group with their name: the recipients of a
    /// Communication Notification, which is how the system tells a group
    /// conversation from a direct one.
    public static func groupMembers(_ dbc: GRDB.Database, chatId: String) throws
        -> [NotificationContentBuilder.SenderInfo] {
        try Row.fetchAll(dbc, sql: """
            SELECT m.userId AS id, u.displayName AS name
            FROM member m LEFT JOIN user u ON u.id = m.userId
            WHERE m.chatId = ?
            """, arguments: [chatId])
            .map { NotificationContentBuilder.SenderInfo(userId: $0["id"], displayName: $0["name"] ?? "") }
    }
}
