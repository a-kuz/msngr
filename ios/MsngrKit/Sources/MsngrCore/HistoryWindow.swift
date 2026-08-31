import Foundation
import GRDB

/// Upward pagination over the local database.
///
/// The ratchet moves forward and destroys the keys of a decrypted message, so
/// the server cannot serve history this device has already read: the local
/// database is the only copy of the conversation. Paging up therefore walks the
/// local database, and the server is asked only for seq ranges this device has
/// never processed.
public enum HistoryWindow {
    /// Messages the feed window grows by per page.
    public static let pageSize = 60
    /// Journal records one server history page returns: Durable Objects read at
    /// most 128 keys per batch, and a longer range comes back truncated.
    public static let serverPageSize = 128
    /// Attempts spent on one unreadable seq before the feed shows a placeholder.
    public static let maxGapAttempts = 3
    /// Seqs that never surface in the feed: the envelope was addressed to
    /// another device, carries our own content, is a tombstone, was processed
    /// without a row of its own (key distribution, edit, reaction), its message
    /// was cleared from this device, or the message names another chat than the
    /// one it was delivered in.
    public static let silentGapReasons: Set<String> = [
        "not_addressed", "own_echo", "deleted", "service", "sender_key", "identity_changed",
        "cleared", MessageRepair.wrongChatReason,
    ]

    // MARK: - Window

    /// Seq floor of the newest `limit` messages; nil when the chat stores none
    /// carrying a seq.
    public static func newestFloor(_ dbc: GRDB.Database, chatId: String, limit: Int) throws -> Int? {
        try Int.fetchOne(dbc, sql: """
            SELECT MIN(seq) FROM (
              SELECT seq FROM message WHERE chatId = ? AND seq IS NOT NULL
              ORDER BY seq DESC LIMIT ?)
            """, arguments: [chatId, limit])
    }

    /// Floor of the next page below `floor`; nil when nothing older is stored.
    public static func floorBelow(_ dbc: GRDB.Database, chatId: String, floor: Int,
                                  limit: Int) throws -> Int? {
        try Int.fetchOne(dbc, sql: """
            SELECT MIN(seq) FROM (
              SELECT seq FROM message WHERE chatId = ? AND seq IS NOT NULL AND seq < ?
              ORDER BY seq DESC LIMIT ?)
            """, arguments: [chatId, floor, limit])
    }

    /// True when the chat stores a message older than the window floor.
    public static func hasOlder(_ dbc: GRDB.Database, chatId: String, floor: Int?) throws -> Bool {
        guard let floor else { return false }
        return try Bool.fetchOne(dbc, sql: """
            SELECT EXISTS(SELECT 1 FROM message WHERE chatId = ? AND seq IS NOT NULL AND seq < ?)
            """, arguments: [chatId, floor]) ?? false
    }

    /// True when the chat stores a message newer than the top of the window, that
    /// is, when the capacity cut the window short of the end of the conversation.
    /// A window whose top message carries no seq is at the end by construction:
    /// unnumbered messages of our own sort above everything the server numbered.
    public static func hasNewer(_ dbc: GRDB.Database, chatId: String, topSeq: Int?) throws -> Bool {
        guard let topSeq else { return false }
        return try Bool.fetchOne(dbc, sql: """
            SELECT EXISTS(SELECT 1 FROM message
            WHERE chatId = ? AND COALESCE(seq, \(unsentOrder)) > ?)
            """, arguments: [chatId, topSeq]) ?? false
    }

    /// Value a message without a seq (own, not yet acknowledged) sorts by: above
    /// everything the server has numbered, so it belongs to the newest page.
    static let unsentOrder = 999_999_999

    /// Window contents, newest first (feed order). The bound is written over
    /// the same expression the ordering uses, so the whole window is one range
    /// on `message_on_chat_feedOrder` instead of a scan of the chat.
    ///
    /// `limit` caps the window from above, counting up from the floor. A floor
    /// that stays put while the reader looks at older messages would otherwise
    /// let the window grow by a row per arriving message, and the window is
    /// re-read on every commit.
    public static func messages(_ dbc: GRDB.Database, chatId: String, floor: Int?,
                                limit: Int? = nil) throws -> [Message] {
        guard let limit else {
            return try Message.fetchAll(dbc, sql: """
                SELECT * FROM message
                WHERE chatId = ? AND COALESCE(seq, \(unsentOrder)) >= ?
                ORDER BY COALESCE(seq, \(unsentOrder)) DESC, sentAt DESC
                """, arguments: [chatId, floor ?? 0])
        }
        return try Message.fetchAll(dbc, sql: """
            SELECT * FROM (
              SELECT * FROM message
              WHERE chatId = ? AND COALESCE(seq, \(unsentOrder)) >= ?
              ORDER BY COALESCE(seq, \(unsentOrder)) ASC, sentAt ASC
              LIMIT ?)
            ORDER BY COALESCE(seq, \(unsentOrder)) DESC, sentAt DESC
            """, arguments: [chatId, floor ?? 0, limit])
    }

    /// The message a chat row previews: the highest seq stored, an unsent send
    /// of our own sorting above everything the server has numbered. Ordering
    /// by seq rather than by timestamp is what keeps the preview from stepping
    /// back to an older message while a backfill is still writing seqs below
    /// the one already shown — a server timestamp is not guaranteed to grow
    /// with seq the way the seq itself is.
    public static func lastMessage(_ dbc: GRDB.Database, chatId: String) throws -> Message? {
        try Message.fetchOne(dbc, sql: """
            SELECT * FROM message WHERE chatId = ? AND kind != 'system'
            ORDER BY COALESCE(seq, \(unsentOrder)) DESC, sentAt DESC LIMIT 1
            """, arguments: [chatId])
    }

    // MARK: - Seq gaps

    /// Seq ranges inside `lower...upper` that `known` does not cover.
    public static func gaps(known: [Int], lower: Int, upper: Int) -> [ClosedRange<Int>] {
        guard lower <= upper else { return [] }
        var out: [ClosedRange<Int>] = []
        var cursor = lower
        for seq in known.sorted() {
            if seq > upper { break }
            if seq > cursor { out.append(cursor...(seq - 1)) }
            cursor = max(cursor, seq + 1)
        }
        if cursor <= upper { out.append(cursor...upper) }
        return out
    }

    /// Seq ranges this device has never processed. Everything up to `syncedSeq`
    /// is processed by construction — the cursor moves only along a contiguous
    /// prefix — so gaps live above it: a seq counts as processed when a message
    /// row, a deferred envelope or a recorded unreadable seq carries it.
    public static func openGaps(_ dbc: GRDB.Database, chatId: String) throws -> [ClosedRange<Int>] {
        guard let chat = try Chat.fetchOne(dbc, key: chatId) else { return [] }
        let lower = chat.syncedSeq + 1
        guard lower <= chat.lastSeq else { return [] }
        var known: [Int] = []
        for table in ["message", "pendingDecrypt", "historyGap"] {
            known += try Int.fetchAll(dbc, sql: """
                SELECT seq FROM \(table) WHERE chatId = ? AND seq IS NOT NULL AND seq >= ?
                """, arguments: [chatId, lower])
        }
        return gaps(known: known, lower: lower, upper: chat.lastSeq)
    }

    // MARK: - Catch-up cursors

    /// Seq each chat resumes its catch-up from.
    ///
    /// The larger of the cursor the server confirmed and the contiguously
    /// applied prefix: `syncedSeq` stops at the first seq this device will
    /// never receive — a message held back by a block, a tombstone — while the
    /// catch-up has to move past it, and the confirmed cursor is what carries
    /// an interrupted run forward instead of restarting it.
    /// `behindOnly` narrows the map to chats whose journal is known to hold
    /// more than the cursor covers.
    public static func catchupCursors(_ dbc: GRDB.Database,
                                      behindOnly: Bool = false) throws -> [String: Int] {
        let condition = behindOnly ? "WHERE MAX(syncedSeq, syncCursor) < lastSeq" : ""
        var out: [String: Int] = [:]
        for row in try Row.fetchAll(
            dbc, sql: "SELECT id, MAX(syncedSeq, syncCursor) AS cursor FROM chat \(condition)") {
            out[row["id"]] = row["cursor"]
        }
        return out
    }

    // MARK: - Unreadable seqs

    /// Records a seq this device could not read, or counts another attempt at
    /// one already recorded. The record keeps the failure out of silence:
    /// pagination stops asking the server for it, and repair has the reason and
    /// the attempt count to work from.
    public static func recordGap(_ dbc: GRDB.Database, chatId: String, seq: Int, reason: String,
                                 fromUserId: String? = nil,
                                 sentAt: Double? = nil, now: Double = Date().timeIntervalSince1970) throws {
        try dbc.execute(sql: """
            INSERT INTO historyGap (chatId, seq, fromUserId, sentAt, reason, attempts, lastTriedAt)
            VALUES (?,?,?,?,?,1,?)
            ON CONFLICT(chatId, seq) DO UPDATE SET
              reason = excluded.reason, attempts = historyGap.attempts + 1,
              lastTriedAt = excluded.lastTriedAt,
              fromUserId = COALESCE(excluded.fromUserId, historyGap.fromUserId),
              sentAt = COALESCE(excluded.sentAt, historyGap.sentAt)
            """, arguments: [chatId, seq, fromUserId, sentAt, reason, now])
    }

    /// Seqs inside the window whose attempts are spent: the feed shows a
    /// placeholder for those, and only for those.
    public static func exhaustedGapSeqs(_ dbc: GRDB.Database, chatId: String,
                                        floor: Int?) throws -> [Int] {
        let placeholders = silentGapReasons.map { _ in "?" }.joined(separator: ",")
        var arguments: [DatabaseValueConvertible] = [chatId, floor ?? 0, maxGapAttempts]
        arguments += silentGapReasons.sorted()
        return try Int.fetchAll(dbc, sql: """
            SELECT seq FROM historyGap
            WHERE chatId = ? AND seq >= ? AND attempts >= ? AND reason NOT IN (\(placeholders))
            ORDER BY seq
            """, arguments: StatementArguments(arguments))
    }
}
