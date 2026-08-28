import Foundation
import GRDB

/// The unread-mention mark of a chat row: whether the messages the reader has
/// not seen yet carry a mention token of this user.
public enum MentionMarks {
    /// How many unread messages mention this user, and the earliest of them:
    /// what the in-chat «@» button shows and where its tap lands.
    public static func unreadMentions(_ dbc: GRDB.Database, chatId: String,
                                      myReadUpTo: Int, ownUserId: String)
        throws -> (count: Int, earliestId: String)? {
        guard !ownUserId.isEmpty else { return nil }
        let rows = try Row.fetchAll(dbc, sql: """
            SELECT id FROM message
            WHERE chatId = ? AND seq > ? AND isOutgoing = 0
              AND deletedForAll = 0 AND text LIKE ?
            ORDER BY seq ASC
            """, arguments: [chatId, myReadUpTo, "%](user:\(ownUserId))%"])
        guard let first = rows.first else { return nil }
        return (count: rows.count, earliestId: first["id"])
    }

    public static func hasUnreadMention(_ dbc: GRDB.Database, chatId: String,
                                        myReadUpTo: Int, ownUserId: String) throws -> Bool {
        guard !ownUserId.isEmpty else { return false }
        return try Bool.fetchOne(dbc, sql: """
            SELECT EXISTS(
                SELECT 1 FROM message
                WHERE chatId = ? AND seq > ? AND isOutgoing = 0
                  AND deletedForAll = 0 AND text LIKE ?
            )
            """, arguments: [chatId, myReadUpTo, "%](user:\(ownUserId))%"]) ?? false
    }
}
