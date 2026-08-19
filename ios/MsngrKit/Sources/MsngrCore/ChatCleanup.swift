import Foundation
import GRDB

/// Dropping this device's copy of a conversation.
///
/// The ratchet moves forward and destroys the keys of every message it opens,
/// so the local database is the only copy this device will ever hold: clearing
/// history is a local act, and the other side keeps what it has.
///
/// What both entry points must not do is move the cursors backwards. `lastSeq`,
/// `syncedSeq` and `syncCursor` say which part of the server's journal this
/// device has already processed; rewind them and the catch-up asks for
/// envelopes whose keys are gone, filling the emptied chat with messages it
/// cannot read. Clearing therefore removes rows and leaves every cursor where
/// it stands; deleting takes the chat row with it and leaves a tombstone
/// carrying the same position, for the case where the chat comes back.
public enum ChatCleanup {
    /// Empties a chat this device stays in.
    ///
    /// `historyGap` survives: those rows are the record of seqs that produced
    /// no message here, and dropping them would reopen the ranges for upward
    /// pagination. The read mark moves to the end of the journal, because the
    /// unread count is derived (`lastSeq - myReadUpTo`) and an emptied chat
    /// holds nothing left to read.
    public static func clearHistory(_ dbc: GRDB.Database, chatId: String,
                                    now: Double = Date().timeIntervalSince1970) throws {
        // above `syncedSeq` the message rows are the only proof that a seq was
        // ever processed: the prefix cursor stalls at the first seq this device
        // will never receive. Deleting them without saying so sends upward
        // pagination back to the server for a range it has already read.
        try dbc.execute(sql: """
            INSERT INTO historyGap (chatId, seq, reason, attempts, lastTriedAt)
            SELECT chatId, seq, 'cleared', 1, ? FROM message
            WHERE chatId = ? AND seq IS NOT NULL
              AND seq > COALESCE((SELECT syncedSeq FROM chat WHERE id = ?), 0)
            ON CONFLICT(chatId, seq) DO NOTHING
            """, arguments: [now, chatId, chatId])
        try dbc.execute(sql: "DELETE FROM message WHERE chatId = ?", arguments: [chatId])
        try dbc.execute(sql: "DELETE FROM outbox WHERE chatId = ?", arguments: [chatId])
        try dbc.execute(sql: "DELETE FROM pendingDecrypt WHERE chatId = ?", arguments: [chatId])
        try dbc.execute(sql: "DELETE FROM pendingApply WHERE chatId = ?", arguments: [chatId])
        try dbc.execute(sql: """
            UPDATE chat SET myReadUpTo = MAX(myReadUpTo, lastSeq), unreadCount = 0 WHERE id = ?
            """, arguments: [chatId])
    }

    /// Removes the chat itself, everything it owns and its ratchet material for
    /// group sending. The pairwise sessions are keyed by peer rather than by
    /// chat and stay: a direct chat that comes back has to decrypt the message
    /// that brought it back.
    public static func deleteChat(_ dbc: GRDB.Database, chatId: String,
                                  now: Double = Date().timeIntervalSince1970) throws {
        if let seq = try Int.fetchOne(
            dbc, sql: "SELECT MAX(lastSeq, syncedSeq, syncCursor) FROM chat WHERE id = ?",
            arguments: [chatId]) {
            try dbc.execute(sql: """
                INSERT INTO chatTombstone (chatId, seq, deletedAt) VALUES (?,?,?)
                ON CONFLICT(chatId) DO UPDATE SET
                  seq = MAX(chatTombstone.seq, excluded.seq), deletedAt = excluded.deletedAt
                """, arguments: [chatId, seq, now])
        }
        for table in ["message", "outbox", "pendingDecrypt", "pendingApply", "pendingAction",
                      "historyGap", "member", "senderKeyIn", "notificationShown",
                      "chatFolderChat", "chatMark"] {
            try dbc.execute(sql: "DELETE FROM \(table) WHERE chatId = ?", arguments: [chatId])
        }
        try dbc.execute(sql: "DELETE FROM senderKeyOut WHERE chatId = ?", arguments: [chatId])
        try dbc.execute(sql: "DELETE FROM chat WHERE id = ?", arguments: [chatId])
    }

    /// Messages whose time is up. They leave the same way a cleared history
    /// does: the row goes, the cursors stay, and a seq above `syncedSeq` is
    /// closed with a `historyGap` record — otherwise upward pagination asks the
    /// server for a range whose keys this device has already destroyed.
    public static func expire(_ dbc: GRDB.Database,
                              now: Double = Date().timeIntervalSince1970) throws {
        try dbc.execute(sql: """
            INSERT INTO historyGap (chatId, seq, reason, attempts, lastTriedAt)
            SELECT m.chatId, m.seq, 'cleared', 1, ? FROM message m
            WHERE m.expiresAt IS NOT NULL AND m.expiresAt <= ? AND m.seq IS NOT NULL
              AND m.seq > COALESCE((SELECT syncedSeq FROM chat WHERE id = m.chatId), 0)
            ON CONFLICT(chatId, seq) DO NOTHING
            """, arguments: [now, now])
        try dbc.execute(sql: "DELETE FROM message WHERE expiresAt IS NOT NULL AND expiresAt <= ?",
                        arguments: [now])
    }

    /// Lets a chat back into the list on this device's own act of opening it.
    /// The tombstone is there to keep a title or a pin from resurrecting a chat
    /// nobody wrote in; opening the conversation again is the opposite case, and
    /// the mark has to go or the chat state that follows is dropped on arrival.
    public static func liftTombstone(_ dbc: GRDB.Database, chatId: String) throws {
        try dbc.execute(sql: "DELETE FROM chatTombstone WHERE chatId = ?", arguments: [chatId])
    }

    /// Position a returning chat starts its cursors from, zero when this device
    /// never deleted it.
    public static func tombstoneSeq(_ dbc: GRDB.Database, chatId: String) throws -> Int {
        try Int.fetchOne(dbc, sql: "SELECT seq FROM chatTombstone WHERE chatId = ?",
                         arguments: [chatId]) ?? 0
    }
}
