import XCTest
import GRDB
@testable import MsngrCore

/// The gallery reads a chat by tab, newest first, one page at a time.
final class ChatGalleryTests: XCTestCase {
    private func photo(_ id: String) -> MediaInfo {
        MediaInfo(type: "photo", mediaId: id, key: "k", hash: "h", size: 10, mime: "image/jpeg")
    }

    /// A chat where every fourth message carries an attachment and the rest is talk.
    private func seed(_ db: DatabaseQueue, count: Int) throws {
        try db.write { dbc in
            var chat = Chat(id: "c1", kind: .direct, title: nil, createdBy: "peer", createdAt: 0,
                            lastSeq: count, syncedSeq: count, lastActivityAt: 0)
            chat.myReadUpTo = count
            try chat.save(dbc)
            for seq in 1...count {
                let kind: MessageKind
                switch seq % 4 {
                case 0: kind = .photo
                case 1: kind = .video
                case 2: kind = .file
                default: kind = .text
                }
                var msg = Message(id: "m\(seq)", chatId: "c1", fromUserId: "peer",
                                  sentAt: Double(seq), kind: kind,
                                  text: kind == .text ? "look at https://example.com/\(seq)" : nil,
                                  status: .sent, isOutgoing: false)
                msg.seq = seq
                if kind != .text { msg.media = photo("blob\(seq)") }
                try msg.save(dbc)
            }
        }
    }

    /// Paging the media tab walks the chat downwards without repeating or
    /// skipping an entry.
    func testMediaPagesWalkTheChatOnce() throws {
        let db = try AppDatabase.openInMemory()
        try seed(db, count: 200)

        var seen: [String] = []
        var cursor: GalleryCursor?
        var pages = 0
        while pages < 20 {
            let page = try db.read { dbc in
                try ChatGallery.page(dbc, chatId: "c1", tab: .media, after: cursor, limit: 10)
            }
            seen += page.entries.map(\.id)
            cursor = page.cursor
            pages += 1
            if page.reachedEnd { break }
        }
        // photo and video: half the chat
        XCTAssertEqual(seen.count, 100)
        XCTAssertEqual(Set(seen).count, 100)
        // newest first
        XCTAssertEqual(seen.first, "m200")
        XCTAssertEqual(seen.last, "m1")
    }

    /// Tabs answer for their own kinds only.
    func testTabsSplitByKind() throws {
        let db = try AppDatabase.openInMemory()
        try seed(db, count: 40)

        let files = try db.read { dbc in
            try ChatGallery.page(dbc, chatId: "c1", tab: .files, after: nil, limit: 100)
        }
        XCTAssertEqual(files.entries.count, 10)
        XCTAssertTrue(files.entries.allSatisfy { $0.kind == .file })

        let voice = try db.read { dbc in
            try ChatGallery.page(dbc, chatId: "c1", tab: .voice, after: nil, limit: 100)
        }
        XCTAssertTrue(voice.entries.isEmpty)
        XCTAssertTrue(voice.reachedEnd)
    }

    /// An album is one message and several entries; each entry knows the message
    /// it belongs to, so a tap on any of them lands on the same bubble.
    func testAlbumExpandsIntoEntries() throws {
        let db = try AppDatabase.openInMemory()
        try db.write { dbc in
            var msg = Message(id: "a1", chatId: "c1", fromUserId: "peer", sentAt: 1,
                              kind: .album, text: nil, status: .sent, isOutgoing: false)
            msg.seq = 1
            msg.album = [photo("one"), photo("two"), photo("three")]
            try msg.save(dbc)
        }
        let page = try db.read { dbc in
            try ChatGallery.page(dbc, chatId: "c1", tab: .media, after: nil)
        }
        XCTAssertEqual(page.entries.count, 3)
        XCTAssertEqual(page.entries.map(\.index), [0, 1, 2])
        XCTAssertEqual(Set(page.entries.map(\.messageId)), ["a1"])
    }

    /// Links come out of message text through the parser the feed draws with,
    /// and a message with several links contributes each of them.
    func testLinksComeFromMessageText() throws {
        let db = try AppDatabase.openInMemory()
        try db.write { dbc in
            for (i, text) in ["go to example.com and to https://docs.example.org/a",
                              "no links at all",
                              "`code.example.com` inside code is not a link"].enumerated() {
                var msg = Message(id: "t\(i)", chatId: "c1", fromUserId: "peer", sentAt: Double(i),
                                  kind: .text, text: text, status: .sent, isOutgoing: false)
                msg.seq = i + 1
                try msg.save(dbc)
            }
        }
        let page = try db.read { dbc in
            try ChatGallery.page(dbc, chatId: "c1", tab: .links, after: nil)
        }
        XCTAssertEqual(page.entries.compactMap(\.link),
                       ["https://example.com", "https://docs.example.org/a"])
        XCTAssertTrue(page.reachedEnd)
    }

    /// A message deleted for everyone leaves the gallery with it.
    func testDeletedMessageLeavesTheGallery() throws {
        let db = try AppDatabase.openInMemory()
        try db.write { dbc in
            var msg = Message(id: "d1", chatId: "c1", fromUserId: "peer", sentAt: 1,
                              kind: .photo, text: nil, status: .sent, isOutgoing: false)
            msg.seq = 1
            msg.media = photo("gone")
            msg.deletedForAll = true
            try msg.save(dbc)
        }
        let page = try db.read { dbc in
            try ChatGallery.page(dbc, chatId: "c1", tab: .media, after: nil)
        }
        XCTAssertTrue(page.entries.isEmpty)
    }

    /// A page is a seek into the index and a short walk: no scan of the chat and
    /// no sort. This is what keeps the grid smooth over thousands of messages.
    func testPageReadsThroughTheIndex() throws {
        let db = try AppDatabase.openInMemory()
        try seed(db, count: 50)
        let plan = try db.read { dbc -> String in
            try Row.fetchAll(dbc, sql: """
                EXPLAIN QUERY PLAN
                SELECT * FROM message
                WHERE chatId = ? AND kind = ? AND deletedForAll = 0
                  AND COALESCE(seq, \(HistoryWindow.unsentOrder)) <= ?
                ORDER BY COALESCE(seq, \(HistoryWindow.unsentOrder)) DESC, sentAt DESC
                LIMIT ?
                """, arguments: ["c1", "photo", 40, 10])
                .map { ($0["detail"] as String?) ?? "" }
                .joined(separator: " | ")
        }
        XCTAssertTrue(plan.contains("message_on_chat_kindOrder"), plan)
        XCTAssertFalse(plan.contains("TEMP B-TREE"), plan)
    }
}
