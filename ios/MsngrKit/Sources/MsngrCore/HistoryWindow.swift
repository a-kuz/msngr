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
    /// Attempts spent on one unreadable seq before the feed shows a placeholder.
    public static let maxGapAttempts = 3
    /// Seqs that never surface in the feed: the envelope was addressed to
    /// another device, carries our own content, is a tombstone, or was
    /// processed without a row of its own (key distribution, edit, reaction).
    public static let silentGapReasons: Set<String> = [
        "not_addressed", "own_echo", "deleted", "service", "sender_key", "identity_changed",
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

    /// Window contents, newest first (feed order). Messages without a seq (own,
    /// not yet acknowledged) belong to the newest page.
    public static func messages(_ dbc: GRDB.Database, chatId: String, floor: Int?) throws -> [Message] {
        try Message.fetchAll(dbc, sql: """
            SELECT * FROM message WHERE chatId = ? AND (seq IS NULL OR seq >= ?)
            ORDER BY COALESCE(seq, 999999999) DESC, sentAt DESC
            """, arguments: [chatId, floor ?? 0])
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

    // MARK: - Unreadable seqs

    /// Records a seq this device could not read, or counts another attempt at
    /// one already recorded. The record keeps the failure out of silence:
    /// pagination stops asking the server for it, and repair has the reason and
    /// the attempt count to work from.
    public static func recordGap(_ dbc: GRDB.Database, chatId: String, seq: Int, reason: String,
                                 msgId: String? = nil, fromUserId: String? = nil,
                                 sentAt: Double? = nil, now: Double = Date().timeIntervalSince1970) throws {
        try dbc.execute(sql: """
            INSERT INTO historyGap (chatId, seq, msgId, fromUserId, sentAt, reason, attempts, lastTriedAt)
            VALUES (?,?,?,?,?,?,1,?)
            ON CONFLICT(chatId, seq) DO UPDATE SET
              reason = excluded.reason, attempts = historyGap.attempts + 1,
              lastTriedAt = excluded.lastTriedAt,
              msgId = COALESCE(excluded.msgId, historyGap.msgId),
              fromUserId = COALESCE(excluded.fromUserId, historyGap.fromUserId),
              sentAt = COALESCE(excluded.sentAt, historyGap.sentAt)
            """, arguments: [chatId, seq, msgId, fromUserId, sentAt, reason, now])
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
