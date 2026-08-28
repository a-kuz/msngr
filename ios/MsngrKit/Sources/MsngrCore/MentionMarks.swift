import Foundation
import GRDB

/// The unread-mention mark of a chat row: whether the messages the reader has
/// not seen yet carry a mention token of this user.
public enum MentionMarks {
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
