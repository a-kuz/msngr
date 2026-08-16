import Foundation
import Combine
import MsngrCore

/// Search inside one chat: the query, the matches it has, and which of them the
/// reader is standing on.
///
/// The matches come from `ChatSearchModel` — the same paged full-text query the
/// chat list runs, scoped to this chat and asking nobody about people. What is
/// added here is the reader's place in the result: how many matches there are,
/// which one the feed shows, and the step to the next or the previous one.
@MainActor
final class ChatSearchSession: ObservableObject {
    /// What is typed in the field. The screen binds to it directly.
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            queryChanged()
        }
    }
    /// Position of the match the feed stands on, nil until one is chosen.
    @Published private(set) var currentIndex: Int?
    /// How many messages of this chat match the query, nil while it is counted.
    @Published private(set) var total: Int?
    /// The list of matches covers the feed. Choosing a match uncovers it.
    @Published var resultsShown = true

    let results: ChatSearchModel
    private let counter: (String) async -> Int?
    private var countTask: Task<Void, Never>?
    private var generation = 0
    private var relay: AnyCancellable?

    init(results: ChatSearchModel, count: @escaping (String) async -> Int?) {
        self.results = results
        self.counter = count
        // the screen watches the session alone, while the matches live one object
        // deeper: their changes are passed on as this object's own
        relay = results.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    convenience init(chatId: String) {
        self.init(results: ChatSearchModel(pages: { query, after in
            await ChatSearchModel.databasePage(query: query, after: after, chatId: chatId)
        }, people: nil),
                  count: { query in await ChatSearchSession.databaseCount(query: query, chatId: chatId) })
    }

    var hits: [MessageSearchHit] { results.hits }
    /// The first page of matches is still being read.
    var searching: Bool { results.searchingMessages }
    /// Nothing in this chat matches what is typed. Until the first page is read an
    /// empty list means the search is still running.
    var foundNothing: Bool { results.messagesReady && results.hits.isEmpty && !query.isEmpty }

    /// There is a match further back in time, either already read or on a page
    /// that has not been asked for yet.
    var canStepOlder: Bool {
        guard let currentIndex else { return !results.hits.isEmpty }
        if let total { return currentIndex + 1 < total }
        return currentIndex + 1 < results.hits.count
    }

    /// There is a match closer to the end of the conversation.
    var canStepNewer: Bool { (currentIndex ?? 0) > 0 }

    /// What the bar under the feed says: the search runs, found nothing, found
    /// this many, or the reader is on the n-th of them.
    var status: String {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Поиск по этому чату" }
        if let currentIndex, currentIndex < results.hits.count {
            guard let total else { return Self.matchesTitle(count: results.hits.count) }
            return "\(currentIndex + 1) из \(total)"
        }
        if searching { return "Ищем в переписке…" }
        if results.hits.isEmpty { return "Ничего не нашлось" }
        return Self.matchesTitle(count: total ?? results.hits.count)
    }

    /// The reader picked a match out of the list.
    func select(_ hit: MessageSearchHit) {
        guard let index = results.hits.firstIndex(where: { $0.id == hit.id }) else { return }
        currentIndex = index
        resultsShown = false
        results.loadMoreIfNeeded(at: hit)
    }

    /// The match one step away: +1 goes back in time, −1 goes towards the end of
    /// the conversation. With nothing chosen yet either direction lands on the
    /// newest match. Returns nil when there is nothing to move onto.
    func step(by offset: Int) async -> MessageSearchHit? {
        guard !results.hits.isEmpty else { return nil }
        resultsShown = false
        guard let current = currentIndex else {
            currentIndex = 0
            return results.hits[0]
        }
        let next = current + offset
        guard next >= 0 else { return nil }
        // the last read match, and the result goes on: the next page is what the
        // step needs, so it is awaited rather than merely started
        if next >= results.hits.count { await results.loadNextPage() }
        guard next < results.hits.count else { return nil }
        currentIndex = next
        results.loadMoreIfNeeded(at: results.hits[next])
        return results.hits[next]
    }

    /// Leaving search: nothing of the query survives it.
    func reset() {
        query = ""
    }

    private func queryChanged() {
        generation += 1
        let generation = self.generation
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        results.update(trimmed)
        currentIndex = nil
        total = nil
        resultsShown = true
        countTask?.cancel()
        guard !trimmed.isEmpty else { return }
        countTask = Task { [weak self] in
            try? await Task.sleep(for: ChatSearchModel.debounce)
            guard !Task.isCancelled, let self else { return }
            let found = await self.counter(trimmed)
            // the query moved on while the count was running
            guard generation == self.generation else { return }
            self.total = found
        }
    }

    /// Russian plural forms of "N matches", for counts ending in 1, in 2 to 4, and
    /// in the rest.
    static func matchesTitle(count: Int) -> String {
        let mod100 = count % 100
        let mod10 = count % 10
        let noun: String
        if mod100 / 10 == 1 {
            noun = "совпадений"
        } else if mod10 == 1 {
            noun = "совпадение"
        } else if (2...4).contains(mod10) {
            noun = "совпадения"
        } else {
            noun = "совпадений"
        }
        return "\(count) \(noun)"
    }

    static func databaseCount(query: String, chatId: String) async -> Int? {
        guard let db = AppState.shared.db else { return nil }
        return try? await db.read { dbc in
            try MessageSearch.count(dbc, query: query, chatId: chatId)
        }
    }
}
