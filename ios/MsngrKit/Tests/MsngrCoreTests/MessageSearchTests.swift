import XCTest
import GRDB
@testable import MsngrCore

/// Full-text search over messages: what it finds, in what order, what it refuses
/// to show, and how a reader walks it page by page.
final class MessageSearchTests: XCTestCase {
    private func seedChat(_ db: DatabaseQueue, id: String, title: String? = nil,
                          isRequest: Bool = false, iAccepted: Bool = true) throws {
        var chat = Chat(id: id, kind: .direct, title: title, createdBy: "peer", createdAt: 0,
                        lastSeq: 0, syncedSeq: 0, lastActivityAt: 0)
        chat.isRequest = isRequest
        chat.iAccepted = iAccepted
        try db.write { dbc in try chat.save(dbc) }
    }

    @discardableResult
    private func seedMessage(_ db: DatabaseQueue, id: String, chatId: String, text: String,
                             at: Double, kind: MessageKind = .text,
                             deletedForAll: Bool = false) throws -> Message {
        var msg = Message(id: id, chatId: chatId, fromUserId: "peer", sentAt: at,
                          kind: kind, text: text, status: .sent, isOutgoing: false)
        msg.msgId = id
        msg.serverTs = at
        msg.deletedForAll = deletedForAll
        try db.write { dbc in try msg.save(dbc) }
        return msg
    }

    private func hits(_ db: DatabaseQueue, _ query: String, chatId: String? = nil,
                      after: MessageSearchCursor? = nil,
                      limit: Int = MessageSearch.pageSize) throws -> MessageSearchPage {
        try db.read { dbc in
            try MessageSearch.page(dbc, query: query, chatId: chatId, after: after, limit: limit)
        }
    }

    // MARK: - What it finds

    /// A word inside a message is found whole and by prefix, so a result appears
    /// while the word is still being typed.
    func testFindsByWholeWordAndByPrefix() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, id: "c1")
        try seedMessage(db, id: "m1", chatId: "c1", text: "Irina arrives tomorrow", at: 10)

        XCTAssertEqual(try hits(db, "Irina").hits.map(\.id), ["m1"])
        XCTAssertEqual(try hits(db, "iri").hits.map(\.id), ["m1"])
        XCTAssertEqual(try hits(db, "IRINA TOMORROW").hits.map(\.id), ["m1"])
        XCTAssertTrue(try hits(db, "irina yesterday").hits.isEmpty)   // every word is required
        XCTAssertTrue(try hits(db, "marina").hits.isEmpty)
    }

    /// Newest match first: that is the useful order when a word appears in years
    /// of conversation.
    func testNewestMatchComesFirst() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, id: "c1")
        try seedChat(db, id: "c2")
        try seedMessage(db, id: "old", chatId: "c1", text: "tickets bought", at: 10)
        try seedMessage(db, id: "new", chatId: "c2", text: "tickets returned", at: 30)
        try seedMessage(db, id: "mid", chatId: "c1", text: "tickets for tomorrow", at: 20)

        XCTAssertEqual(try hits(db, "tickets").hits.map(\.id), ["new", "mid", "old"])
    }

    /// One chat, when the search runs inside it — the same query with one more
    /// predicate.
    func testScopedToOneChat() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, id: "c1")
        try seedChat(db, id: "c2")
        try seedMessage(db, id: "m1", chatId: "c1", text: "contract signed", at: 10)
        try seedMessage(db, id: "m2", chatId: "c2", text: "contract in the mail", at: 20)

        XCTAssertEqual(try hits(db, "contract", chatId: "c1").hits.map(\.id), ["m1"])
        XCTAssertEqual(try hits(db, "contract").hits.map(\.id), ["m2", "m1"])
    }

    /// A caption of a photo is message text and is searched like any other.
    func testFindsCaptionOfAttachment() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, id: "c1")
        try seedMessage(db, id: "m1", chatId: "c1", text: "receipt from the cafe", at: 10, kind: .photo)

        XCTAssertEqual(try hits(db, "receipt").hits.map(\.kind), [.photo])
    }

    // MARK: - What it must not show

    /// A chat waiting to be accepted hides its content everywhere; search is not
    /// the hole that leaks it.
    func testRequestChatKeepsItsContentOutOfResults() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, id: "c1", isRequest: true, iAccepted: false)
        try seedChat(db, id: "c2")
        try seedMessage(db, id: "hidden", chatId: "c1", text: "secret word", at: 20)
        try seedMessage(db, id: "shown", chatId: "c2", text: "secret word", at: 10)

        XCTAssertEqual(try hits(db, "secret").hits.map(\.id), ["shown"])
        XCTAssertTrue(try hits(db, "secret", chatId: "c1").hits.isEmpty)
    }

    /// Deleted messages and system notes are not part of the conversation.
    func testSkipsDeletedAndSystemMessages() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, id: "c1")
        try seedMessage(db, id: "gone", chatId: "c1", text: "deleted word", at: 20,
                        deletedForAll: true)
        try seedMessage(db, id: "note", chatId: "c1", text: "deleted word", at: 15,
                        kind: .system)
        try seedMessage(db, id: "kept", chatId: "c1", text: "deleted word", at: 10)

        XCTAssertEqual(try hits(db, "deleted").hits.map(\.id), ["kept"])
    }

    /// Punctuation and spaces alone are not a search: an empty query matches
    /// nothing instead of everything.
    func testQueryWithoutWordsMatchesNothing() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, id: "c1")
        try seedMessage(db, id: "m1", chatId: "c1", text: "anything", at: 10)

        XCTAssertTrue(try hits(db, "  ").hits.isEmpty)
        XCTAssertTrue(try hits(db, "***").hits.isEmpty)
        XCTAssertNil(MessageSearch.ftsQuery("-"))
    }

    /// The query text goes through the search syntax without meaning anything in
    /// it: quotes, stars and operators are cut down to plain words.
    func testQuerySyntaxInTypedTextIsHarmless() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, id: "c1")
        try seedMessage(db, id: "m1", chatId: "c1", text: "report ready", at: 10)

        XCTAssertEqual(try hits(db, "\"report\"").hits.map(\.id), ["m1"])
        XCTAssertEqual(try hits(db, "report*").hits.map(\.id), ["m1"])
        // an operator is read as one more word to find, not as syntax
        XCTAssertTrue(try hits(db, "report OR estimate").hits.isEmpty)
        XCTAssertTrue(try hits(db, "report NEAR/2 estimate").hits.isEmpty)
    }

    // MARK: - Paging

    /// Pages walk the whole result without repeating a hit or losing one, and the
    /// last page says the search is over.
    func testPagesWalkEveryHitOnce() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, id: "c1")
        for i in 1...25 {
            try seedMessage(db, id: "m\(i)", chatId: "c1", text: "estimate number \(i)",
                            at: Double(i))
        }

        var seen: [String] = []
        var cursor: MessageSearchCursor?
        var pages = 0
        while pages < 10 {
            let page = try hits(db, "estimate", after: cursor, limit: 10)
            seen += page.hits.map(\.id)
            cursor = page.cursor
            pages += 1
            if page.reachedEnd { break }
        }
        XCTAssertEqual(seen.count, 25)
        XCTAssertEqual(Set(seen).count, 25)
        XCTAssertEqual(seen.first, "m25")
        XCTAssertEqual(seen.last, "m1")
        XCTAssertEqual(pages, 3)
    }

    /// Messages sharing one timestamp sit on the page boundary without being
    /// delivered twice or skipped: the cursor names the last hit, not its time.
    func testPageBoundaryOnEqualTimestamps() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, id: "c1")
        for i in 1...6 {
            try seedMessage(db, id: "m\(i)", chatId: "c1", text: "meeting \(i)", at: 100)
        }

        let first = try hits(db, "meeting", limit: 3)
        XCTAssertEqual(first.hits.count, 3)
        let second = try hits(db, "meeting", after: first.cursor, limit: 3)
        XCTAssertEqual(Set(first.hits.map(\.id)).intersection(second.hits.map(\.id)), [])
        XCTAssertEqual(Set(first.hits.map(\.id)).union(second.hits.map(\.id)).count, 6)
    }

    /// The first page costs the same whether the word appears ten times or ten
    /// thousand: the reader gets a screen, not the whole result.
    func testFirstPageOverALargeChat() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, id: "c1")
        try db.write { dbc in
            for i in 1...20_000 {
                var msg = Message(id: "m\(i)", chatId: "c1", fromUserId: "peer",
                                  sentAt: Double(i), kind: .text,
                                  text: "ordinary chatter about the trip number \(i)",
                                  status: .sent, isOutgoing: false)
                msg.msgId = "m\(i)"
                msg.serverTs = Double(i)
                try msg.save(dbc)
            }
        }

        let started = Date()
        let page = try hits(db, "trip", limit: 24)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(page.hits.count, 24)
        XCTAssertEqual(page.hits.first?.id, "m20000")
        XCTAssertFalse(page.reachedEnd)
        XCTAssertLessThan(elapsed, 1.0, "first page took \(elapsed)s")

        // counting every match is what the bar under the feed waits for, and it
        // waits on the reader's screen: joined to the index instead of reading it
        // through a subquery, this same count took nineteen seconds
        let countStarted = Date()
        let total = try db.read { dbc in try MessageSearch.count(dbc, query: "trip", chatId: "c1") }
        let counting = Date().timeIntervalSince(countStarted)
        XCTAssertEqual(total, 20_000)
        XCTAssertLessThan(counting, 1.0, "counting took \(counting)s")
    }

    // MARK: - Counting

    /// Walking the matches one by one needs the size of the whole result, and it
    /// is counted over the same messages the pages deliver: this chat, nothing
    /// deleted, nothing system, no unaccepted request.
    func testCountsWhatThePagesWouldDeliver() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, id: "c1")
        try seedChat(db, id: "c2")
        try seedChat(db, id: "req", isRequest: true, iAccepted: false)
        for i in 1...30 {
            try seedMessage(db, id: "m\(i)", chatId: "c1", text: "estimate \(i)", at: Double(i))
        }
        try seedMessage(db, id: "other", chatId: "c2", text: "estimate elsewhere", at: 40)
        try seedMessage(db, id: "hidden", chatId: "req", text: "estimate hidden", at: 50)
        try seedMessage(db, id: "gone", chatId: "c1", text: "estimate deleted", at: 60,
                        deletedForAll: true)
        try seedMessage(db, id: "note", chatId: "c1", text: "estimate system", at: 70, kind: .system)

        try db.read { dbc in
            XCTAssertEqual(try MessageSearch.count(dbc, query: "estimate", chatId: "c1"), 30)
            XCTAssertEqual(try MessageSearch.count(dbc, query: "estimate"), 31)
            XCTAssertEqual(try MessageSearch.count(dbc, query: "estimate", chatId: "req"), 0)
            XCTAssertEqual(try MessageSearch.count(dbc, query: "nothing", chatId: "c1"), 0)
            // spaces and punctuation alone are not a search here either
            XCTAssertEqual(try MessageSearch.count(dbc, query: " ", chatId: "c1"), 0)
        }
    }

    // MARK: - Snippet

    /// The row shows the line the word was written in, with the word marked.
    func testSnippetCarriesTextAndMatchedRange() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, id: "c1")
        try seedMessage(db, id: "m1", chatId: "c1",
                        text: "Irina said the tickets are already bought", at: 10)

        let snippet = try XCTUnwrap(try hits(db, "tickets").hits.first?.snippet)
        XCTAssertTrue(snippet.text.contains("tickets"))
        XCTAssertFalse(snippet.text.contains("\u{2}"))
        XCTAssertFalse(snippet.text.contains("\u{3}"))
        let matched = snippet.matches.map { String(snippet.text[$0]).lowercased() }
        XCTAssertEqual(matched, ["tickets"])
    }

    /// A long message is cut around the match, so the row shows where the word is
    /// rather than the beginning of the text.
    func testSnippetOfLongMessageIsCutAroundTheMatch() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, id: "c1")
        let filler = Array(repeating: "word", count: 60).joined(separator: " ")
        try seedMessage(db, id: "m1", chatId: "c1", text: "\(filler) rarity \(filler)", at: 10)

        let snippet = try XCTUnwrap(try hits(db, "rarity").hits.first?.snippet)
        XCTAssertTrue(snippet.text.contains("rarity"))
        XCTAssertLessThan(snippet.text.count, 200)
    }

    /// A hit points at the message the way the feed knows it, so the jump from a
    /// result lands on the bubble.
    func testHitCarriesFeedIdentity() throws {
        let db = try AppDatabase.openInMemory()
        try seedChat(db, id: "c1")
        var pending = Message(id: "local-1", chatId: "c1", fromUserId: "me", sentAt: 20,
                              kind: .text, text: "draft sent", status: .sending,
                              isOutgoing: true)
        pending.msgId = nil
        try db.write { dbc in try pending.save(dbc) }
        try seedMessage(db, id: "srv-1", chatId: "c1", text: "draft accepted", at: 10)

        let found = try hits(db, "draft").hits
        XCTAssertEqual(found.map(\.messageId), ["local-1", "srv-1"])
        XCTAssertEqual(found.map(\.chatId), ["c1", "c1"])
    }
}
