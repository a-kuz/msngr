import XCTest
import MsngrCore
@testable import Msngr

private func searchHit(_ id: String) -> MessageSearchHit {
    MessageSearchHit(id: id, chatId: "c1", messageId: id, fromUserId: "peer",
                     kind: .text, sortedAt: 1,
                     snippet: MessageSearchSnippet(text: id, matches: []))
}

/// Search inside one chat: where the reader stands in the result, and what a step
/// through the matches is allowed to do at the edges of what has been read.
@MainActor
final class ChatSearchSessionTests: XCTestCase {
    /// The status is compared through the catalog, not against a literal: the
    /// test asserts which string the bar chose, in whatever language the host
    /// device runs.
    private func s(_ key: String.LocalizationValue) -> String { String(localized: key) }

    /// A result cut into pages of `size`, handed out the way the database does.
    private func session(_ ids: [String], pageSize size: Int = 24,
                         total: Int? = nil) -> ChatSearchSession {
        let results = ChatSearchModel(pages: { _, cursor in
            let start = cursor.flatMap { c in ids.firstIndex(of: c.id).map { $0 + 1 } } ?? 0
            let page = Array(ids[start..<min(start + size, ids.count)])
            return MessageSearchPage(hits: page.map(searchHit),
                                     cursor: page.last.map { MessageSearchCursor(order: 1, id: $0) },
                                     reachedEnd: start + size >= ids.count)
        }, people: nil)
        return ChatSearchSession(results: results, count: { _ in total ?? ids.count })
    }

    /// Long enough for the debounce and the read behind it.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(500))
    }

    /// The steps walk the matches back in time and forward again, and the bar says
    /// which one of how many the reader is on.
    func testStepsWalkTheMatchesBothWays() async throws {
        let session = self.session(["a", "b", "c"])
        session.query = "word"
        try await settle()

        // nothing chosen yet: the first step lands on the newest match
        var moved = await session.step(by: 1)
        XCTAssertEqual(moved?.id, "a")
        XCTAssertEqual(session.status, s("\(1) of \(3)"))
        moved = await session.step(by: 1)
        XCTAssertEqual(moved?.id, "b")
        moved = await session.step(by: -1)
        XCTAssertEqual(moved?.id, "a")
        XCTAssertEqual(session.status, s("\(1) of \(3)"))
        // the newest match has nothing newer above it
        XCTAssertFalse(session.canStepNewer)
        moved = await session.step(by: -1)
        XCTAssertNil(moved)
    }

    /// The last match of the page read so far is not the last match: the step
    /// waits for the next page instead of stopping there.
    func testStepPastTheReadPageWaitsForTheNextOne() async throws {
        let session = self.session(["a", "b", "c", "d"], pageSize: 2)
        session.query = "word"
        try await settle()
        XCTAssertEqual(session.hits.count, 2)
        XCTAssertTrue(session.canStepOlder)

        for expected in ["a", "b", "c", "d"] {
            let moved = await session.step(by: 1)
            XCTAssertEqual(moved?.id, expected)
        }
        XCTAssertEqual(session.status, s("\(4) of \(4)"))
        XCTAssertFalse(session.canStepOlder)
        let past = await session.step(by: 1)
        XCTAssertNil(past)
    }

    /// Picking a match out of the list puts the reader on it and takes the list off
    /// the feed.
    func testChoosingAMatchFromTheListSetsThePlace() async throws {
        let session = self.session(["a", "b", "c"])
        session.query = "word"
        try await settle()

        session.select(session.hits[2])
        XCTAssertEqual(session.currentIndex, 2)
        XCTAssertFalse(session.resultsShown)
        XCTAssertEqual(session.status, s("\(3) of \(3)"))
    }

    /// Retyping the query throws away the place in the old result: the third match
    /// of the previous word is nothing in the new one.
    func testNewQueryForgetsThePlaceInTheOldResult() async throws {
        let session = self.session(["a", "b", "c"])
        session.query = "word"
        try await settle()
        session.select(session.hits[2])

        session.query = "other"
        XCTAssertNil(session.currentIndex)
        XCTAssertNil(session.total)
        XCTAssertTrue(session.resultsShown)
        XCTAssertEqual(session.status, s("Searching messages…"))
    }

    /// Until the first page is read an empty result means the search is running,
    /// and the screen must not call it "nothing found" before that.
    func testEmptyIsNotAnAnswerBeforeTheFirstPage() async throws {
        let session = self.session([])
        session.query = "word"
        XCTAssertFalse(session.foundNothing)
        XCTAssertEqual(session.status, s("Searching messages…"))

        try await settle()
        XCTAssertTrue(session.foundNothing)
        XCTAssertEqual(session.status, s("Nothing found"))
        XCTAssertFalse(session.canStepOlder)
        XCTAssertFalse(session.canStepNewer)
    }

    /// The result goes on past the page that has been read, and the step onwards
    /// stays available because the count says so.
    func testCountKeepsTheStepAliveBeyondTheReadPage() async throws {
        let session = self.session(["a", "b"], pageSize: 2, total: 40)
        session.query = "word"
        try await settle()

        XCTAssertEqual(session.status, ChatSearchSession.matchesTitle(count: 40))
        session.select(session.hits[1])
        XCTAssertEqual(session.status, s("\(2) of \(40)"))
        XCTAssertTrue(session.canStepOlder)
    }

    /// The page that has been read is not the result: while the matches are still
    /// being counted the bar says so instead of naming the size of the page.
    func testThePageSizeIsNotAnnouncedAsTheResultSize() async throws {
        let results = ChatSearchModel(pages: { _, _ in
            MessageSearchPage(hits: ["a", "b"].map(searchHit), cursor: nil, reachedEnd: false)
        }, people: nil)
        let session = ChatSearchSession(results: results, count: { _ in
            try? await Task.sleep(for: .milliseconds(600))
            return 900
        })
        session.query = "word"
        try await settle()

        XCTAssertEqual(session.hits.count, 2)
        XCTAssertEqual(session.status, s("Searching messages…"))
        session.select(session.hits[0])
        XCTAssertEqual(session.status, s("Searching messages…"))

        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(session.status, s("\(1) of \(900)"))
    }

    /// Leaving search leaves nothing of it behind.
    func testResetClearsTheSearch() async throws {
        let session = self.session(["a", "b"])
        session.query = "word"
        try await settle()
        session.select(session.hits[0])

        session.reset()
        XCTAssertTrue(session.query.isEmpty)
        XCTAssertTrue(session.hits.isEmpty)
        XCTAssertNil(session.currentIndex)
        XCTAssertFalse(session.foundNothing)
        XCTAssertEqual(session.status, s("Search this chat"))
    }

    /// The match count goes through the catalog's plural rule: the number is in
    /// the title, and the singular form differs from the plural in every
    /// language the catalog carries.
    func testMatchesTitlePlurals() {
        XCTAssertTrue(ChatSearchSession.matchesTitle(count: 40).contains("40"))
        XCTAssertNotEqual(ChatSearchSession.matchesTitle(count: 1).replacingOccurrences(of: "1", with: "5"),
                          ChatSearchSession.matchesTitle(count: 5))
    }
}
