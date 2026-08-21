import Foundation
import GRDB

/// One message found by full text, with the piece of text the match sits in.
public struct MessageSearchHit: Identifiable, Equatable, Sendable {
    /// Local message id, unique across chats — the list identity and what a
    /// jump into the feed scrolls to.
    public var id: String
    public var chatId: String
    public var fromUserId: String
    public var kind: MessageKind
    /// Ordering key of the hit: server time when the message has one.
    public var sortedAt: Double
    public var snippet: MessageSearchSnippet

    public init(id: String, chatId: String, fromUserId: String,
                kind: MessageKind, sortedAt: Double, snippet: MessageSearchSnippet) {
        self.id = id
        self.chatId = chatId
        self.fromUserId = fromUserId
        self.kind = kind
        self.sortedAt = sortedAt
        self.snippet = snippet
    }
}

/// A line of text around the match, and where inside it the matched words are.
public struct MessageSearchSnippet: Equatable, Sendable {
    public var text: String
    public var matches: [Range<String.Index>]

    public init(text: String, matches: [Range<String.Index>]) {
        self.text = text
        self.matches = matches
    }
}

/// Where a page continues from: the last hit it delivered. Ordering runs on the
/// pair (time, id), so the messages sharing one timestamp still have one place
/// each and a page boundary can fall between them.
public struct MessageSearchCursor: Equatable, Sendable {
    public var order: Double
    public var id: String

    public init(order: Double, id: String) {
        self.order = order
        self.id = id
    }
}

public struct MessageSearchPage: Sendable {
    public var hits: [MessageSearchHit]
    public var cursor: MessageSearchCursor?
    /// Nothing older matches the query.
    public var reachedEnd: Bool

    public init(hits: [MessageSearchHit], cursor: MessageSearchCursor?, reachedEnd: Bool) {
        self.hits = hits
        self.cursor = cursor
        self.reachedEnd = reachedEnd
    }
}

/// Full-text search over message text, newest match first, one page at a time.
///
/// One entry point serves both the chat list (`chatId` nil — every chat at once)
/// and one chat (`chatId` given): the two differ by a single predicate, and the
/// ordering, paging and snippet are the same work.
///
/// A chat waiting to be accepted hides its content everywhere else, so its
/// messages never reach a result here either.
public enum MessageSearch {
    /// Hits one page carries. About two screens of rows.
    public static let pageSize = 24
    /// Markers `snippet()` wraps the match in. Control characters: no text of a
    /// message can contain them, so parsing the snippet back cannot mistake
    /// written text for a marker.
    private static let openMark = "\u{2}"
    private static let closeMark = "\u{3}"

    /// One page of hits. `after` is nil for the first page.
    ///
    /// Returns an empty page for a query with no searchable characters (spaces
    /// and punctuation alone), rather than matching everything.
    public static func page(_ dbc: GRDB.Database, query: String, chatId: String? = nil,
                            after: MessageSearchCursor? = nil,
                            limit: Int = pageSize) throws -> MessageSearchPage {
        guard let match = ftsQuery(query) else {
            return MessageSearchPage(hits: [], cursor: nil, reachedEnd: true)
        }
        var conditions = ["messageFts MATCH ?", "message.deletedForAll = 0",
                          "message.kind != 'system'",
                          "NOT (chat.isRequest = 1 AND chat.iAccepted = 0)"]
        var arguments: [DatabaseValueConvertible] = [openMark, closeMark, match]
        if let chatId {
            conditions.append("message.chatId = ?")
            arguments.append(chatId)
        }
        if let after {
            conditions.append("""
                (COALESCE(message.serverTs, message.sentAt) < ?
                 OR (COALESCE(message.serverTs, message.sentAt) = ? AND message.id < ?))
                """)
            arguments += [after.order, after.order, after.id]
        }
        // one row over the page tells whether anything older matches
        arguments.append(limit + 1)
        let rows = try Row.fetchAll(dbc, sql: """
            SELECT message.id, message.chatId, message.fromUserId,
                   message.kind,
                   COALESCE(message.serverTs, message.sentAt) AS sortedAt,
                   snippet(messageFts, ?, ?, '…', -1, 12) AS snip
            FROM message
            JOIN messageFts ON messageFts.rowid = message.rowid
            JOIN chat ON chat.id = message.chatId
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY sortedAt DESC, message.id DESC
            LIMIT ?
            """, arguments: StatementArguments(arguments))
        let page = Array(rows.prefix(limit)).map(hit(from:))
        let last = page.last.map { MessageSearchCursor(order: $0.sortedAt, id: $0.id) }
        return MessageSearchPage(hits: page,
                                 cursor: last ?? after,
                                 reachedEnd: rows.count <= limit)
    }

    /// How many messages the query matches. The reader walking matches one by one
    /// is told where they stand in the whole result, which a page cannot say.
    ///
    /// The matches come out of a subquery instead of a join: with the index joined
    /// in, a count with no `LIMIT` to stop it walks the messages and asks the index
    /// about each one, which on a chat of twenty thousand takes nineteen seconds
    /// against ten milliseconds here (measured in `swift test` on an in-memory
    /// database of that size).
    public static func count(_ dbc: GRDB.Database, query: String,
                             chatId: String? = nil) throws -> Int {
        guard let match = ftsQuery(query) else { return 0 }
        var conditions = ["message.rowid IN (SELECT rowid FROM messageFts WHERE messageFts MATCH ?)",
                          "message.deletedForAll = 0", "message.kind != 'system'",
                          "NOT (chat.isRequest = 1 AND chat.iAccepted = 0)"]
        var arguments: [DatabaseValueConvertible] = [match]
        if let chatId {
            conditions.append("message.chatId = ?")
            arguments.append(chatId)
        }
        return try Int.fetchOne(dbc, sql: """
            SELECT COUNT(*)
            FROM message
            JOIN chat ON chat.id = message.chatId
            WHERE \(conditions.joined(separator: " AND "))
            """, arguments: StatementArguments(arguments)) ?? 0
    }

    private static func hit(from row: Row) -> MessageSearchHit {
        let id: String = row["id"]
        return MessageSearchHit(id: id,
                                chatId: row["chatId"],
                                fromUserId: row["fromUserId"],
                                kind: MessageKind(rawValue: row["kind"]) ?? .text,
                                sortedAt: row["sortedAt"],
                                snippet: snippet(from: row["snip"] ?? ""))
    }

    // MARK: - Query

    /// The MATCH expression for what a person typed: every word is required, and
    /// the last one matches by prefix so a result appears while the word is still
    /// being typed.
    ///
    /// Words are cut on everything that is not a letter or a digit, so nothing of
    /// the FTS query syntax survives the trip from the text field.
    static func ftsQuery(_ raw: String) -> String? {
        let terms = raw.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard let last = terms.last else { return nil }
        return (terms.dropLast() + ["\(last)*"]).joined(separator: " ")
    }

    // MARK: - Snippet

    /// Turns the marked-up snippet into plain text plus the ranges to highlight.
    static func snippet(from marked: String) -> MessageSearchSnippet {
        var text = ""
        var bounds: [(Int, Int)] = []
        var openedAt: Int?
        var offset = 0
        for character in marked {
            switch String(character) {
            case openMark:
                openedAt = offset
            case closeMark:
                if let start = openedAt { bounds.append((start, offset)) }
                openedAt = nil
            default:
                text.append(character)
                offset += 1
            }
        }
        // ranges are built once the text is whole: a String index taken while the
        // string is still growing does not survive the next append
        let matches = bounds.compactMap { start, end -> Range<String.Index>? in
            guard let from = text.index(text.startIndex, offsetBy: start, limitedBy: text.endIndex),
                  let to = text.index(text.startIndex, offsetBy: end, limitedBy: text.endIndex),
                  from < to else { return nil }
            return from..<to
        }
        return MessageSearchSnippet(text: text, matches: matches)
    }
}
