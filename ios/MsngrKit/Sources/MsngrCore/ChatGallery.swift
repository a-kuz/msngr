import Foundation
import GRDB

/// Everything a chat has carried besides plain talk, grouped the way a person
/// looks for it: pictures, documents, voice, links.
public enum GalleryTab: String, CaseIterable, Sendable {
    case media, files, voice, links

    /// Message kinds a tab reads. Each kind is queried on its own so a read
    /// stays one range of `message_on_chat_kindOrder`: an `IN` over the indexed
    /// column returns the rows unordered and costs a sort of the whole chat.
    var kinds: [MessageKind] {
        switch self {
        case .media: return [.photo, .video, .album]
        case .files: return [.file]
        case .voice: return [.voice]
        case .links: return [.text]
        }
    }
}

/// One entry of the gallery. An album contributes one entry per attachment and
/// a message with several links one entry per link, so `id` carries the
/// position inside the message while `messageId` stays the way back to the feed.
public struct GalleryEntry: Identifiable, Equatable, Sendable {
    public var id: String
    /// Identity the feed knows the message by: the server msgId, or the local
    /// id while the message is still on its way out.
    public var messageId: String
    /// Position of the attachment or link inside its message.
    public var index: Int
    public var kind: MessageKind
    public var sentAt: Double
    public var media: MediaInfo?
    /// Absolute URL, for the links tab.
    public var link: String?
    /// The line the link was written in.
    public var linkContext: String?

    public init(id: String, messageId: String, index: Int, kind: MessageKind, sentAt: Double,
                media: MediaInfo? = nil, link: String? = nil, linkContext: String? = nil) {
        self.id = id
        self.messageId = messageId
        self.index = index
        self.kind = kind
        self.sentAt = sentAt
        self.media = media
        self.link = link
        self.linkContext = linkContext
    }
}

/// Where a page continues from: the feed order value of the last message read,
/// and the messages already delivered at that value. The bound in SQL stays
/// inclusive — a plain range on the index — and the few messages that share an
/// order value (own messages still without a seq) are dropped by id.
public struct GalleryCursor: Equatable, Sendable {
    public var order: Int
    public var delivered: Set<String>

    public init(order: Int, delivered: Set<String>) {
        self.order = order
        self.delivered = delivered
    }
}

public struct GalleryPage: Sendable {
    public var entries: [GalleryEntry]
    public var cursor: GalleryCursor?
    /// Nothing older is stored for this tab.
    public var reachedEnd: Bool

    public init(entries: [GalleryEntry], cursor: GalleryCursor?, reachedEnd: Bool) {
        self.entries = entries
        self.cursor = cursor
        self.reachedEnd = reachedEnd
    }
}

/// Reads a chat's attachments and links, newest first, one page at a time.
///
/// The feed's ordering is reused (`COALESCE(seq, unsentOrder) DESC, sentAt
/// DESC`), so an entry sits in the gallery where its message sits in the chat.
public enum ChatGallery {
    /// Messages one page carries. Three columns of a grid fill about seven rows
    /// with it, a screen and a bit ahead of the reader.
    public static let pageSize = 60
    /// Text messages read per attempt while collecting links. Most carry none,
    /// so the scan takes bigger bites than the page it fills.
    static let linkScanBatch = 400

    /// One page of a tab. `after` is nil for the first page.
    public static func page(_ dbc: GRDB.Database, chatId: String, tab: GalleryTab,
                            after: GalleryCursor? = nil, limit: Int = pageSize) throws -> GalleryPage {
        tab == .links
            ? try linkPage(dbc, chatId: chatId, after: after, limit: limit)
            : try mediaPage(dbc, chatId: chatId, tab: tab, after: after, limit: limit)
    }

    // MARK: - Attachments

    private static func mediaPage(_ dbc: GRDB.Database, chatId: String, tab: GalleryTab,
                                  after: GalleryCursor?, limit: Int) throws -> GalleryPage {
        // one ordered range per kind, merged afterwards: the merge puts the page
        // in feed order without asking SQLite to sort anything
        var merged: [Message] = []
        var capped = false
        for kind in tab.kinds {
            let rows = try messages(dbc, chatId: chatId, kind: kind, after: after, limit: limit + 1)
            capped = capped || rows.count > limit
            merged += rows
        }
        merged = sorted(fresh(merged, after: after))
        // every kind came back short of its cap, so the tab holds nothing else
        let hasMore = merged.count > limit || capped
        let page = Array(merged.prefix(limit))
        return GalleryPage(entries: page.flatMap(entries(of:)),
                           cursor: cursor(after: page, previous: after),
                           reachedEnd: !hasMore)
    }

    private static func messages(_ dbc: GRDB.Database, chatId: String, kind: MessageKind,
                                 after: GalleryCursor?, limit: Int) throws -> [Message] {
        let bound = after == nil ? "" : "AND COALESCE(seq, \(HistoryWindow.unsentOrder)) <= ?"
        var arguments: [DatabaseValueConvertible] = [chatId, kind.rawValue]
        if let after { arguments.append(after.order) }
        arguments.append(limit)
        return try Message.fetchAll(dbc, sql: """
            SELECT * FROM message
            WHERE chatId = ? AND kind = ? AND deletedForAll = 0 \(bound)
            ORDER BY COALESCE(seq, \(HistoryWindow.unsentOrder)) DESC, sentAt DESC
            LIMIT ?
            """, arguments: StatementArguments(arguments))
    }

    /// Drops what the previous page already returned at the boundary value.
    private static func fresh(_ messages: [Message], after: GalleryCursor?) -> [Message] {
        guard let after else { return messages }
        return messages.filter { !after.delivered.contains($0.id) }
    }

    private static func sorted(_ messages: [Message]) -> [Message] {
        messages.sorted {
            order($0) != order($1) ? order($0) > order($1) : $0.sentAt > $1.sentAt
        }
    }

    /// Cursor for the page just produced: its last order value, plus every
    /// message delivered at that value (this page's and, when the page did not
    /// move past it, the previous one's).
    private static func cursor(after page: [Message], previous: GalleryCursor?) -> GalleryCursor? {
        guard let last = page.last else { return previous }
        let bound = order(last)
        var delivered = Set(page.filter { order($0) == bound }.map(\.id))
        if let previous, previous.order == bound { delivered.formUnion(previous.delivered) }
        return GalleryCursor(order: bound, delivered: delivered)
    }

    /// Attachments of one message as gallery entries.
    static func entries(of message: Message) -> [GalleryEntry] {
        let feedId = message.msgId ?? message.id
        if let album = message.album, !album.isEmpty {
            return album.enumerated().map { i, media in
                GalleryEntry(id: "\(message.id)#\(i)", messageId: feedId, index: i,
                             kind: media.type == "video" ? .video : .photo,
                             sentAt: message.sentAt, media: media)
            }
        }
        guard let media = message.media else { return [] }
        return [GalleryEntry(id: message.id, messageId: feedId, index: 0, kind: message.kind,
                             sentAt: message.sentAt, media: media)]
    }

    // MARK: - Links

    /// Link entries, taken from message text by the same parser that draws it in
    /// the feed. Text without a link contributes nothing, so the scan keeps
    /// reading batches until the page is full or the chat runs out.
    private static func linkPage(_ dbc: GRDB.Database, chatId: String, after: GalleryCursor?,
                                 limit: Int) throws -> GalleryPage {
        var entries: [GalleryEntry] = []
        var cursor = after
        var reachedEnd = false
        while entries.count < limit {
            let rows = try messages(dbc, chatId: chatId, kind: .text, after: cursor,
                                    limit: linkScanBatch)
            let batch = sorted(fresh(rows, after: cursor))
            for message in batch { entries += linkEntries(of: message) }
            guard let next = Self.cursor(after: batch, previous: cursor) else {
                reachedEnd = true
                break
            }
            cursor = next
            if rows.count < linkScanBatch {
                reachedEnd = true
                break
            }
        }
        return GalleryPage(entries: entries, cursor: cursor, reachedEnd: reachedEnd)
    }

    static func linkEntries(of message: Message) -> [GalleryEntry] {
        guard let text = message.text, !text.isEmpty else { return [] }
        let feedId = message.msgId ?? message.id
        let context = text.split(separator: "\n").first.map(String.init) ?? text
        return MessageMarkdown.links(in: text).enumerated().map { i, link in
            GalleryEntry(id: "\(message.id)#link\(i)", messageId: feedId, index: i, kind: .text,
                         sentAt: message.sentAt, link: link, linkContext: context)
        }
    }

    static func order(_ message: Message) -> Int { message.seq ?? HistoryWindow.unsentOrder }
}
