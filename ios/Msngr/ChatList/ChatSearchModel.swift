import Foundation
import Combine
import MsngrCore

/// The slow half of chat-list search: full text over messages, and people from
/// the server. The fast half, chats by title, is computed in `ChatListModel` on
/// the keystroke itself and never waits for this one.
///
/// Every new query cancels the one before it: results carry a generation number,
/// and an answer with an old number is not applied even if it arrives after a
/// fresher one.
@MainActor
final class ChatSearchModel: ObservableObject {
    @Published private(set) var hits: [MessageSearchHit] = []
    @Published private(set) var people: [APIClient.UserDTO] = []
    /// The first page of messages for the current query is still being read.
    @Published private(set) var searchingMessages = false
    @Published private(set) var searchingPeople = false
    /// The first page for the current query has been read. Until it has, an
    /// empty list means "still searching", not "nothing found".
    @Published private(set) var messagesReady = false

    /// Pause before the query: typing runs faster than searching is worth.
    static let debounce = Duration.milliseconds(180)
    /// How many characters make it worth asking the server about people. The
    /// new-chat list asks for the same.
    static let peopleMinimum = 2
    /// How many rows short of the end of the list the next page is read.
    private static let prefetch = 8

    private var query = ""
    /// The generation of the results: it grows with every new query, and answers
    /// carrying someone else's number are thrown away.
    private var generation = 0
    private var cursor: MessageSearchCursor?
    private var reachedEnd = true
    private var loadingPage = false
    private var messagesTask: Task<Void, Never>?
    private var peopleTask: Task<Void, Never>?

    private let app = AppState.shared

    /// A new query. The previous results are cleared at once, so that results
    /// belonging to an older query never sit under a fresh one.
    func update(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != query else { return }
        query = trimmed
        generation += 1
        let generation = self.generation
        messagesTask?.cancel()
        peopleTask?.cancel()
        hits = []
        people = []
        cursor = nil
        reachedEnd = true
        loadingPage = false
        messagesReady = trimmed.isEmpty
        searchingMessages = !trimmed.isEmpty
        searchingPeople = trimmed.count >= Self.peopleMinimum
        guard !trimmed.isEmpty else { return }

        messagesTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.loadFirstPage(query: trimmed, generation: generation)
        }
        guard searchingPeople else { return }
        peopleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }
            let found = (try? await self.app.api.searchUsers(trimmed)) ?? []
            guard !Task.isCancelled, generation == self.generation else { return }
            self.people = found
            self.searchingPeople = false
        }
    }

    /// Reads the next page as the end of the list nears; the rows near the
    /// bottom edge call it.
    func loadMoreIfNeeded(at hit: MessageSearchHit) {
        guard !loadingPage, !reachedEnd,
              let index = hits.firstIndex(where: { $0.id == hit.id }),
              index >= hits.count - Self.prefetch else { return }
        let generation = self.generation
        let query = self.query
        let cursor = self.cursor
        loadingPage = true
        Task { [weak self] in
            let page = await self?.page(query: query, after: cursor)
            // the query changed while the page was loading: the page is no longer about it
            guard let self, generation == self.generation else { return }
            self.loadingPage = false
            guard let page else { return }
            self.hits += page.hits
            self.cursor = page.cursor
            self.reachedEnd = page.reachedEnd
        }
    }

    private func loadFirstPage(query: String, generation: Int) async {
        loadingPage = true
        let page = await self.page(query: query, after: nil)
        guard generation == self.generation else { return }
        hits = page?.hits ?? []
        cursor = page?.cursor
        reachedEnd = page?.reachedEnd ?? true
        loadingPage = false
        searchingMessages = false
        messagesReady = true
    }

    private func page(query: String, after: MessageSearchCursor?) async -> MessageSearchPage? {
        guard let db = app.db else { return nil }
        return try? await db.read { dbc in
            try MessageSearch.page(dbc, query: query, after: after)
        }
    }
}

/// Opens the conversation with a person: either its chat already exists, or the
/// server creates one there and then. Search and the new-chat list share this path.
enum DirectChat {
    static func open(userId: String) async -> String? {
        let app = AppState.shared
        guard let chatId = try? await app.api.createChat(kind: "direct", memberIds: [userId],
                                                         title: nil) else { return nil }
        try? await app.engine.refreshSnapshot()
        return chatId
    }
}
