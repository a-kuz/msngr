import XCTest
import MsngrCore
@testable import Msngr

/// The slow half of chat-list search: what a query still in flight is allowed to
/// do once a newer one has been typed.
@MainActor
final class ChatSearchModelTests: XCTestCase {
    private func hit(_ id: String) -> MessageSearchHit {
        MessageSearchHit(id: id, chatId: "c1", messageId: id, fromUserId: "peer",
                         kind: .text, sortedAt: 1,
                         snippet: MessageSearchSnippet(text: id, matches: []))
    }

    private func page(_ ids: [String]) -> MessageSearchPage {
        MessageSearchPage(hits: ids.map(hit), cursor: nil, reachedEnd: true)
    }

    private func person(_ username: String) throws -> APIClient.UserDTO {
        let json = #"{"id":"\#(username)","username":"\#(username)","display_name":"\#(username)"}"#
        return try JSONDecoder().decode(APIClient.UserDTO.self, from: Data(json.utf8))
    }

    /// A wait that does not end early when the task around it is cancelled — a
    /// database read and a request already sent behave the same way, and the point
    /// of these tests is what happens when such an answer comes back too late.
    private static func stall(_ seconds: Double) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                continuation.resume()
            }
        }
    }

    /// A word is typed on: the first query is already running when the next letters
    /// arrive, and its answer must not land on top of the fresher one.
    func testLateAnswerOfAnOlderQueryIsDropped() async throws {
        let model = ChatSearchModel(pages: { query, _ in
            // the first query is the slow one: it answers after the second is done
            if query == "ир" { await Self.stall(0.6) }
            return MessageSearchPage(hits: [MessageSearchHit(id: query, chatId: "c1", messageId: query,
                                                             fromUserId: "peer", kind: .text, sortedAt: 1,
                                                             snippet: MessageSearchSnippet(text: query, matches: []))],
                                     cursor: nil, reachedEnd: true)
        }, people: { _ in [] })

        model.update("ир")
        // past the debounce: the older query is in flight, not waiting to start
        try await Task.sleep(for: .milliseconds(300))
        model.update("ирина")
        try await Task.sleep(for: .milliseconds(1_200))

        XCTAssertEqual(model.hits.map(\.id), ["ирина"])
        XCTAssertFalse(model.searchingMessages)
        XCTAssertTrue(model.messagesReady)
    }

    /// The same for people: the server answering about an older prefix does not
    /// replace the people already on screen.
    func testLatePeopleOfAnOlderQueryAreDropped() async throws {
        let older = try person("ир")
        let newer = try person("ирина")
        let model = ChatSearchModel(pages: { _, _ in nil }, people: { query in
            if query == "ир" {
                await Self.stall(0.6)
                return [older]
            }
            return [newer]
        })

        model.update("ир")
        try await Task.sleep(for: .milliseconds(300))
        model.update("ирина")
        try await Task.sleep(for: .milliseconds(1_200))

        XCTAssertEqual(model.people.map(\.username), ["ирина"])
        XCTAssertFalse(model.searchingPeople)
    }

    /// Typing runs ahead of searching: the letters of one word cost one query, not
    /// one per keystroke.
    func testKeystrokesOfOneWordCostOneQuery() async throws {
        let asked = Asked()
        let model = ChatSearchModel(pages: { query, _ in
            await asked.add(query)
            return MessageSearchPage(hits: [], cursor: nil, reachedEnd: true)
        }, people: { _ in [] })

        for prefix in ["и", "ир", "ири", "ирин", "ирина"] {
            model.update(prefix)
            try await Task.sleep(for: .milliseconds(30))
        }
        try await Task.sleep(for: .milliseconds(600))

        let queries = await asked.queries
        XCTAssertEqual(queries, ["ирина"])
    }

    /// Until the first page is read an empty list means "still searching", and the
    /// screen has to be able to tell the two apart.
    func testResultIsNotCalledEmptyBeforeTheFirstPage() async throws {
        let model = ChatSearchModel(pages: { _, _ in
            try? await Task.sleep(for: .milliseconds(400))
            return MessageSearchPage(hits: [], cursor: nil, reachedEnd: true)
        }, people: { _ in [] })

        model.update("ирина")
        XCTAssertTrue(model.searchingMessages)
        XCTAssertFalse(model.messagesReady)

        try await Task.sleep(for: .milliseconds(900))
        XCTAssertFalse(model.searchingMessages)
        XCTAssertTrue(model.messagesReady)
        XCTAssertTrue(model.hits.isEmpty)
    }

    /// Clearing the field leaves nothing of the previous query behind.
    func testClearingTheFieldClearsTheResult() async throws {
        let found = try person("irina")
        let model = ChatSearchModel(pages: { query, _ in
            MessageSearchPage(hits: [MessageSearchHit(id: query, chatId: "c1", messageId: query,
                                                      fromUserId: "peer", kind: .text, sortedAt: 1,
                                                      snippet: MessageSearchSnippet(text: query, matches: []))],
                              cursor: nil, reachedEnd: true)
        }, people: { _ in [found] })

        model.update("irina")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(model.hits.isEmpty)
        XCTAssertFalse(model.people.isEmpty)

        model.update("")
        XCTAssertTrue(model.hits.isEmpty)
        XCTAssertTrue(model.people.isEmpty)
        XCTAssertFalse(model.searchingMessages)
        XCTAssertTrue(model.messagesReady)
    }
}

/// The queries a fake source was asked for, collected from whatever task the
/// model runs them on.
private actor Asked {
    private(set) var queries: [String] = []
    func add(_ query: String) { queries.append(query) }
}
