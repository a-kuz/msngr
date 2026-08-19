import Foundation
import Combine
import MsngrCore

/// The slow half of chat-list search: full text over messages, and people from
/// the server. The fast half, chats by title, is computed in `ChatListModel` on
/// the keystroke itself and never waits for this one.
///
/// Search inside one chat runs on the same model: the pages come scoped to that
/// chat and there is nobody to ask about people.
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

    /// Where the two halves of a result come from. The screen takes the database
    /// and the server; a test hands over answers whose timing it decides itself.
    /// A nil people source means this search has no people in it at all.
    private let pages: (String, MessageSearchCursor?) async -> MessageSearchPage?
    private let peopleSource: ((String) async -> [APIClient.UserDTO])?

    init(pages: @escaping (String, MessageSearchCursor?) async -> MessageSearchPage?
            = { await ChatSearchModel.databasePage(query: $0, after: $1) },
         people: ((String) async -> [APIClient.UserDTO])? = ChatSearchModel.serverPeople) {
        self.pages = pages
        self.peopleSource = people
    }

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
        searchingPeople = peopleSource != nil && trimmed.count >= Self.peopleMinimum
        guard !trimmed.isEmpty else { return }

        messagesTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.loadFirstPage(query: trimmed, generation: generation)
        }
        guard searchingPeople, let peopleSource else { return }
        peopleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }
            let found = await peopleSource(trimmed)
            guard generation == self.generation else { return }
            self.people = found
            self.searchingPeople = false
        }
    }

    /// Reads the next page as the end of the list nears; the rows near the
    /// bottom edge call it.
    func loadMoreIfNeeded(at hit: MessageSearchHit) {
        guard let index = hits.firstIndex(where: { $0.id == hit.id }),
              index >= hits.count - Self.prefetch else { return }
        Task { [weak self] in await self?.loadNextPage() }
    }

    /// One more page of the current query, appended to the hits already there.
    /// Does nothing while a page is in flight or while nothing older matches, so
    /// a reader walking the matches can await it before stepping past the end.
    func loadNextPage() async {
        guard !loadingPage, !reachedEnd else { return }
        let generation = self.generation
        let query = self.query
        let cursor = self.cursor
        loadingPage = true
        let page = await self.page(query: query, after: cursor)
        // the query changed while the page was loading: the page is no longer about it
        guard generation == self.generation else { return }
        loadingPage = false
        guard let page else { return }
        hits += page.hits
        self.cursor = page.cursor
        reachedEnd = page.reachedEnd
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
        await pages(query, after)
    }

    /// The message half of a result: one page of the full-text index, over every
    /// chat or over the one the search was opened in.
    static func databasePage(query: String, after: MessageSearchCursor?,
                             chatId: String? = nil) async -> MessageSearchPage? {
        guard let db = AppState.shared.db else { return nil }
        return try? await db.read { dbc in
            try MessageSearch.page(dbc, query: query, chatId: chatId, after: after)
        }
    }

    /// The people half: the same server call the new-chat list makes.
    static func serverPeople(query: String) async -> [APIClient.UserDTO] {
        (try? await AppState.shared.api.searchUsers(query)) ?? []
    }
}

/// Opens the conversation with a person: either its chat already exists, or the
/// server creates one there and then. Search and the new-chat list share this path.
enum DirectChat {
    static func open(userId: String) async -> String? {
        let app = AppState.shared
        guard let chatId = try? await app.api.createChat(kind: "direct", memberIds: [userId],
                                                         title: nil) else { return nil }
        // the chat may be one this device deleted: opening it is a decision to
        // have it back, so the tombstone that would drop its state is lifted
        if let db = await MainActor.run(body: { app.db }) {
            try? await db.write { dbc in
                try ChatCleanup.liftTombstone(dbc, chatId: chatId)
            }
        }
        try? await app.engine.refreshSnapshot()
        return chatId
    }
}
