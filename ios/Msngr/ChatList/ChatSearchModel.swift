import Foundation
import Combine
import MsngrCore

/// Медленная половина поиска по чат-листу: полнотекст по сообщениям и люди с
/// сервера. Быстрая половина — чаты по названию — считается в `ChatListModel`
/// прямо на нажатие клавиши и этого не ждёт.
///
/// Каждый набор символов отменяет предыдущий: у выдачи есть номер, и ответ со
/// старым номером не применяется, даже если пришёл позже свежего.
@MainActor
final class ChatSearchModel: ObservableObject {
    @Published private(set) var hits: [MessageSearchHit] = []
    @Published private(set) var people: [APIClient.UserDTO] = []
    /// Первая страница сообщений по текущему запросу ещё читается.
    @Published private(set) var searchingMessages = false
    @Published private(set) var searchingPeople = false
    /// Первая страница по текущему запросу прочитана: до этого пустой список —
    /// это «ещё ищем», а не «ничего нет».
    @Published private(set) var messagesReady = false

    /// Пауза перед запросом: набор идёт быстрее, чем имеет смысл искать.
    static let debounce = Duration.milliseconds(180)
    /// Со скольких символов есть смысл спрашивать сервер о людях. Столько же
    /// требует поиск в листе нового чата.
    static let peopleMinimum = 2
    /// За сколько строк до конца списка читается следующая страница.
    private static let prefetch = 8

    private var query = ""
    /// Номер выдачи: растёт на каждый новый запрос, ответы с чужим номером
    /// выбрасываются.
    private var generation = 0
    private var cursor: MessageSearchCursor?
    private var reachedEnd = true
    private var loadingPage = false
    private var messagesTask: Task<Void, Never>?
    private var peopleTask: Task<Void, Never>?

    private let app = AppState.shared

    /// Новый запрос: результаты предыдущего снимаются сразу, чтобы под свежим
    /// запросом ни секунды не лежала чужая выдача.
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

    /// Догрузка на подходе к концу списка: вызывается строками у нижнего края.
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
            // выдача сменилась, пока читалась страница: она уже не про этот запрос
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

/// Открыть переписку с человеком: у неё либо уже есть чат, либо сервер заводит
/// его на месте. Одним путём ходят и поиск, и лист нового чата.
enum DirectChat {
    static func open(userId: String) async -> String? {
        let app = AppState.shared
        guard let chatId = try? await app.api.createChat(kind: "direct", memberIds: [userId],
                                                         title: nil) else { return nil }
        try? await app.engine.refreshSnapshot()
        return chatId
    }
}
