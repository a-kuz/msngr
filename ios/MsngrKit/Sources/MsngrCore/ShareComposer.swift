import Foundation
import GRDB

/// What the share extension writes: the shared photo, file or link goes into
/// the chosen chat as an ordinary outgoing message. The extension has no
/// socket and no worker, so it leaves the row in the outbox exactly the way a
/// send made offline is left, and the app's own drain takes it out from there.
public enum ShareComposer {
    public struct ChatRow: Sendable, Equatable {
        public let id: String
        public let title: String
        public let isGroup: Bool
        public let lastActivityAt: Double
    }

    /// The chats the picker offers, most recently active first. A direct
    /// chat is titled by its peer, the way the chat list titles it.
    public static func chats(_ dbc: Database, ownUserId: String) throws -> [ChatRow] {
        let rows = try Row.fetchAll(dbc, sql: """
            SELECT id, kind, title, lastActivityAt FROM chat
            WHERE isRequest = 0
            ORDER BY lastActivityAt DESC
            LIMIT 50
            """)
        return try rows.map { row in
            let id: String = row["id"]
            let kind: String = row["kind"]
            let title: String
            switch kind {
            case "direct":
                let peerId = id.split(separator: ":").dropFirst()
                    .first { $0 != ownUserId }.map(String.init)
                title = try peerId.flatMap {
                    try String.fetchOne(dbc, sql: "SELECT displayName FROM user WHERE id = ?",
                                        arguments: [$0])
                } ?? "…"
            case "saved":
                title = CoreStrings.string("Saved Messages")
            default:
                title = row["title"] ?? CoreStrings.string("Group")
            }
            return ChatRow(id: id, title: title, isGroup: kind == "group",
                           lastActivityAt: row["lastActivityAt"] ?? 0)
        }
    }

    /// One plain content message into the outbox: the row the feed shows and
    /// the entry the app's worker uploads, encrypts and sends.
    public static func enqueue(_ dbc: Database, content: ContentPayload,
                               chatId: String, ownUserId: String) throws {
        let now = Date().timeIntervalSince1970
        let clientMsgId = UUID().uuidString
        var msg = Message(id: clientMsgId, chatId: chatId, fromUserId: ownUserId, sentAt: now,
                          kind: MessageKind(rawValue: content.kind) ?? .text,
                          text: content.text, status: .sending, isOutgoing: true)
        msg.clientMsgId = clientMsgId
        msg.media = content.media
        try msg.save(dbc)
        try OutboxItem(clientMsgId: clientMsgId, chatId: chatId, createdAt: now,
                       payload: try JSONEncoder().encode(content),
                       scheduledFor: nil).save(dbc)
        try dbc.execute(sql: "UPDATE chat SET lastActivityAt = ? WHERE id = ?",
                        arguments: [now, chatId])
    }
}
