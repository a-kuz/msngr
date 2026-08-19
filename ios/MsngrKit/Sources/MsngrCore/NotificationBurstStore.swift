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
    public static func claim(_ dbc: GRDB.Database, chatId: String, msgId: String, seq: Int,
                             now: Double = Date().timeIntervalSince1970) throws -> Bool {
        try dbc.execute(sql: """
            INSERT OR IGNORE INTO notificationShown (msgId, chatId, seq, shownAt)
            VALUES (?,?,?,?)
            """, arguments: [msgId, chatId, seq, now])
        return dbc.changesCount > 0
    }

    /// Same claim from outside a transaction of its own.
    @discardableResult
    public static func claim(_ db: DatabaseQueue, chatId: String, msgId: String, seq: Int,
                             now: Double = Date().timeIntervalSince1970) async -> Bool {
        (try? await db.write { dbc in
            try claim(dbc, chatId: chatId, msgId: msgId, seq: seq, now: now)
        }) ?? false
    }

    public static func isShown(_ dbc: GRDB.Database, msgId: String) throws -> Bool {
        try Bool.fetchOne(dbc, sql: "SELECT EXISTS(SELECT 1 FROM notificationShown WHERE msgId = ?)",
                          arguments: [msgId]) ?? false
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
                               now: Double = Date().timeIntervalSince1970) throws -> BurstPlan {
        try db.write { dbc -> BurstPlan in
            // The messages the pushes carry are written first: everything below
            // — the banner text, the seqs a chat is missing, the count of what
            // is unread — is read from the database, and this is what puts them
            // there. One transaction covers the ratchet step and the row it
            // produced, so an extension the system kills leaves neither behind.
            if let writer, !envelopes.isEmpty {
                for item in items.sorted(by: { $0.seq < $1.seq }) {
                    guard let envelope = envelopes[item.msgId] else { continue }
                    let outcome = writer.write(dbc, item: item, envelope: envelope, now: now)
                    journal?.record(.stored, msgId: item.msgId, seq: item.seq,
                                    detail: outcome.rawValue)
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
                state[item.msgId] = BurstItemState(
                    alreadyShown: try isShown(dbc, msgId: item.msgId),
                    read: item.seq <= (chat?.myReadUpTo ?? 0),
                    muted: MuteState.isMuted(muted: chat?.muted ?? false,
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
                guard try claim(dbc, chatId: item.chatId, msgId: item.msgId, seq: item.seq, now: now) else {
                    plan.steps[i].outcome = .skip(.duplicate)
                    continue
                }
                switch try content(dbc, item: item, chat: chats[item.chatId],
                                   showsMessageText: showsMessageText) {
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

    static func content(_ dbc: GRDB.Database, item: BurstItem, chat: Chat?,
                        showsMessageText: Bool) throws -> BurstContent {
        guard let chat else { return .fromPush }
        let message = try Message.fetchOne(dbc, sql: "SELECT * FROM message WHERE msgId = ?",
                                           arguments: [item.msgId])
        let senderId = message?.fromUserId
        let sender = try senderId.flatMap { try User.fetchOne(dbc, key: $0) }
        let senderInfo = NotificationContentBuilder.SenderInfo(
            userId: senderId ?? "",
            displayName: sender?.displayName ?? "",
            avatarId: sender?.avatarId)
        let chatInfo = NotificationContentBuilder.ChatInfo(
            chatId: chat.id, isGroup: chat.kind == .group, title: chat.title)
        if ChatPrivacy.hidesContent(chat) {
            return .built(NotificationContentBuilder.requestContent(chat: chatInfo, sender: senderInfo))
        }
        guard let message else { return .fromPush }
        guard let built = NotificationContentBuilder.build(
            message: message, chat: chatInfo, sender: senderInfo,
            showsMessageText: showsMessageText) else { return .silent }
        return .built(built)
    }
}
