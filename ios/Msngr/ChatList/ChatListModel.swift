import Foundation
import Combine
import GRDB
import MsngrCore

/// Строка чат-листа: чат + производные данные для отображения.
struct ChatListItem: Identifiable, Equatable {
    var chat: Chat
    var peer: User?          // для direct
    var lastMessage: Message?
    var typingText: String?  // "печатает…"
    var id: String { chat.id }

    var title: String {
        if chat.kind == .direct { return peer?.displayName ?? "…" }
        return chat.title ?? "Группа"
    }
}

/// Одна выдача наблюдения: весь список чатов и всё, из чего собираются вкладки.
/// Папки читаются тем же наблюдением, что и чаты, поэтому список и его вкладки
/// всегда описывают одно и то же состояние БД.
private struct ChatListSnapshot {
    var chats: [Chat]
    var peers: [String: User]
    var lasts: [String: Message]
    var folders: [ChatFolder]
    var pins: [String: [String: ChatFolderPin]]
}

@MainActor
final class ChatListModel: ObservableObject {
    @Published var items: [ChatListItem] = []
    @Published var requests: [ChatListItem] = []
    @Published var archived: [ChatListItem] = []
    /// Вкладки над списком, в порядке пользователя. «Все» вкладкой не является:
    /// это весь список без папок.
    @Published var folders: [ChatFolder] = []
    /// Выбранная вкладка; nil — «Все».
    @Published var selectedFolderId: String?
    /// Сколько чатов с непрочитанным в каждой папке; ключ nil-вкладки — "".
    @Published private(set) var folderUnread: [String: Int] = [:]
    /// Состав папок: id папки → id чатов. Пересчитывается один раз на выдачу
    /// наблюдения, а не на каждое переключение вкладки.
    private var membership: [String: Set<String>] = [:]
    @Published var searchText = ""
    @Published var searchResults: [ChatListItem] = []
    /// true после первой выдачи наблюдения БД — до этого список не «пустой», а грузится
    @Published var loaded = false

    private var cancellable: AnyCancellable?
    private var typing: [String: (userId: String, until: Date)] = [:]
    private var typingTask: Task<Void, Never>?
    /// Таймеры снятия «печатает…» по чатам: без них индикатор гаснет только
    /// при следующем событии (ленивое истечение) и может залипнуть.
    private var typingClearTasks: [String: Task<Void, Never>] = [:]
    private let app = AppState.shared

    private var started = false

    func start() {
        // db создаётся асинхронно в bootstrap; при холодном старте он может быть
        // ещё не готов — тогда ждём готовности, иначе список останется пустым
        guard !started, let db = app.db else { return }
        started = true
        let ownId = app.session?.userId ?? ""
        cancellable = ValueObservation
            .tracking { dbc -> ChatListSnapshot in
                let chats = try Chat.fetchAll(dbc, sql: "SELECT * FROM chat ORDER BY pinned DESC, lastActivityAt DESC")
                var peers: [String: User] = [:]
                var lasts: [String: Message] = [:]
                for chat in chats {
                    if chat.kind == .direct {
                        if let peerId = try String.fetchOne(
                            dbc, sql: "SELECT userId FROM member WHERE chatId = ? AND userId != ?",
                            arguments: [chat.id, ownId]),
                           let peer = try User.fetchOne(dbc, key: peerId) {
                            peers[chat.id] = peer
                        }
                    }
                    if let m = try Message.fetchOne(
                        dbc, sql: """
                        SELECT * FROM message WHERE chatId = ? AND kind != 'system'
                        ORDER BY COALESCE(serverTs, sentAt) DESC LIMIT 1
                        """, arguments: [chat.id]) {
                        lasts[chat.id] = m
                    }
                }
                return ChatListSnapshot(chats: chats, peers: peers, lasts: lasts,
                                        folders: try ChatFolderStore.all(dbc),
                                        pins: try ChatFolderStore.pins(dbc))
            }
            .publisher(in: db, scheduling: .async(onQueue: .main))
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] snapshot in
                guard let self else { return }
                let all = snapshot.chats.map { chat in
                    ChatListItem(chat: chat, peer: snapshot.peers[chat.id], lastMessage: snapshot.lasts[chat.id],
                                 typingText: self.typingLabel(chat.id, snapshot.peers[chat.id]))
                }
                self.requests = all.filter { $0.chat.isRequest }
                self.archived = all.filter { $0.chat.archived && !$0.chat.isRequest }
                self.items = all.filter { !$0.chat.archived && !$0.chat.isRequest }
                self.folders = snapshot.folders
                self.rebuildMembership(pins: snapshot.pins)
                self.loaded = true
                self.updateSearch()
            })

        // typing из engine
        typingTask?.cancel()
        typingTask = Task { [weak self] in
            guard let engine = self?.app.engine else { return }
            for await ev in engine.typingStream.subscribe() {
                guard let self else { return }
                if ev.kind != nil {
                    self.typing[ev.chatId] = (ev.userId, Date().addingTimeInterval(5))
                    self.typingClearTasks[ev.chatId]?.cancel()
                    self.typingClearTasks[ev.chatId] = Task { [weak self, chatId = ev.chatId] in
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        guard let self, !Task.isCancelled else { return }
                        self.typing.removeValue(forKey: chatId)
                        self.typingClearTasks[chatId] = nil
                        self.refreshTyping()
                    }
                } else {
                    self.typing.removeValue(forKey: ev.chatId)
                    self.typingClearTasks[ev.chatId]?.cancel()
                    self.typingClearTasks[ev.chatId] = nil
                }
                self.refreshTyping()
            }
        }
    }

    private func typingLabel(_ chatId: String, _ peer: User?) -> String? {
        guard let t = typing[chatId], t.until > Date() else { return nil }
        return "печатает…"
    }

    private func refreshTyping() {
        items = items.map { item in
            var it = item
            it.typingText = typingLabel(it.chat.id, it.peer)
            return it
        }
    }

    // MARK: - Папки

    /// Раскладывает список по папкам: один проход по чатам на папку за выдачу
    /// наблюдения. Дальше вкладка переключается по готовому составу.
    ///
    /// Папки собираются из `items` — то есть из чатов без архива и без заявок.
    /// Архив и заявки живут наверху «Всех» и во вкладки не попадают: это
    /// состояния входящего потока, а не тема переписки, и повтор их в папках
    /// удваивал бы одно и то же непрочитанное в двух местах.
    private func rebuildMembership(pins: [String: [String: ChatFolderPin]]) {
        let candidates = items.map { item in
            (candidate: ChatFolderCandidate(chatId: item.chat.id,
                                            isGroup: item.chat.kind == .group,
                                            hasUnread: item.chat.unreadCount > 0,
                                            peerId: item.peer?.id),
             countsUnread: item.chat.unreadCount > 0
                && !MuteState.isMuted(muted: item.chat.muted, mutedUntil: item.chat.mutedUntil))
        }
        var membership: [String: Set<String>] = [:]
        var unread: [String: Int] = ["": candidates.filter(\.countsUnread).count]
        for folder in folders {
            var ids: Set<String> = []
            var unreadChats = 0
            for row in candidates
            where ChatFolderMembership.matches(row.candidate, rules: folder.rules,
                                               pin: pins[folder.id]?[row.candidate.chatId]) {
                ids.insert(row.candidate.chatId)
                if row.countsUnread { unreadChats += 1 }
            }
            membership[folder.id] = ids
            unread[folder.id] = unreadChats
        }
        self.membership = membership
        self.folderUnread = unread
        if let selected = selectedFolderId, !folders.contains(where: { $0.id == selected }) {
            selectedFolderId = nil    // папку удалили, пока она была открыта
        }
    }

    /// Строки вкладки. Состав папки уже посчитан наблюдением, поэтому
    /// переключение вкладки — проход по готовому списку, а не запрос в БД.
    func items(in folderId: String?) -> [ChatListItem] {
        guard let folderId, let ids = membership[folderId] else { return items }
        return items.filter { ids.contains($0.id) }
    }

    /// В какие папки чат положен вручную или попал по правилу.
    func folders(containing chatId: String) -> Set<String> {
        Set(membership.filter { $0.value.contains(chatId) }.keys)
    }

    /// Что сейчас лежит в папке — и по правилу, и вручную.
    func chatIds(in folder: ChatFolder) -> Set<String> { membership[folder.id] ?? [] }

    /// Сохраняет папку целиком: имя, правила и её состав. Одна транзакция —
    /// список ни на миг не видит новые правила со старым составом.
    ///
    /// Состав задаётся набором чатов, которые должны оказаться в папке. Что
    /// приносит правило, там не хранится; вручную записываются только
    /// расхождения: чат, которого правило не даёт, и чат, который правило даёт,
    /// а пользователь его убрал.
    func saveFolder(_ folder: ChatFolder?, title: String, rules: ChatFolderRules,
                    chatIds: Set<String>) {
        let candidates = items.map { item in
            ChatFolderCandidate(chatId: item.chat.id,
                                isGroup: item.chat.kind == .group,
                                hasUnread: item.chat.unreadCount > 0,
                                peerId: item.peer?.id)
        }
        Task {
            try? await app.db.write { dbc in
                let folderId: String
                if let folder {
                    try ChatFolderStore.rename(dbc, folderId: folder.id, title: title)
                    try ChatFolderStore.setRules(dbc, folderId: folder.id, rules: rules)
                    folderId = folder.id
                } else {
                    folderId = try ChatFolderStore.create(dbc, title: title, rules: rules).id
                }
                for candidate in candidates {
                    let byRule = ChatFolderMembership.matches(candidate, rules: rules, pin: nil)
                    let wanted = chatIds.contains(candidate.chatId)
                    let pin: ChatFolderPin? = wanted == byRule ? nil
                        : (wanted ? .included : .excluded)
                    try ChatFolderStore.setPin(dbc, folderId: folderId,
                                               chatId: candidate.chatId, pin: pin)
                }
            }
        }
    }

    func deleteFolder(_ folder: ChatFolder) {
        Task { try? await app.db.write { dbc in try ChatFolderStore.delete(dbc, folderId: folder.id) } }
    }

    func reorderFolders(_ ordered: [ChatFolder]) {
        let ids = ordered.map(\.id)
        Task { try? await app.db.write { dbc in try ChatFolderStore.reorder(dbc, orderedIds: ids) } }
    }

    /// Кладёт чат в папку или убирает его оттуда. Убранный из папки по правилу
    /// чат запоминается исключением, иначе правило вернуло бы его сразу.
    func setChat(_ chatId: String, inFolder folder: ChatFolder, included: Bool) {
        guard let item = items.first(where: { $0.id == chatId }) else { return }
        let candidate = ChatFolderCandidate(chatId: chatId,
                                            isGroup: item.chat.kind == .group,
                                            hasUnread: item.chat.unreadCount > 0,
                                            peerId: item.peer?.id)
        let matchesRule = ChatFolderMembership.matches(candidate, rules: folder.rules, pin: nil)
        let pin: ChatFolderPin? = included ? (matchesRule ? nil : .included)
                                           : (matchesRule ? .excluded : nil)
        Task {
            try? await app.db.write { dbc in
                try ChatFolderStore.setPin(dbc, folderId: folder.id, chatId: chatId, pin: pin)
            }
        }
    }

    func updateSearch() {
        guard !searchText.isEmpty else {
            searchResults = []
            return
        }
        let q = searchText.lowercased()
        searchResults = (items + archived).filter {
            $0.title.lowercased().contains(q) || ($0.peer?.username.lowercased().contains(q) ?? false)
        }
    }

    // MARK: - Действия

    func togglePin(_ item: ChatListItem) {
        Task {
            try? await app.db.write { dbc in
                try dbc.execute(sql: "UPDATE chat SET pinned = NOT pinned WHERE id = ?", arguments: [item.chat.id])
            }
            try? await app.api.setChatFlags(item.chat.id, pinned: !item.chat.pinned)
        }
    }

    /// Свайп мьютит бессрочно; срок выбирается в профиле чата.
    func toggleMute(_ item: ChatListItem) {
        let muted = !MuteState.isMuted(muted: item.chat.muted, mutedUntil: item.chat.mutedUntil)
        Task {
            try? await app.db.write { dbc in
                try dbc.execute(sql: "UPDATE chat SET muted = ?, mutedUntil = NULL WHERE id = ?",
                                arguments: [muted, item.chat.id])
            }
            try? await app.api.setChatFlags(item.chat.id, muted: muted)
        }
    }

    func toggleArchive(_ item: ChatListItem) {
        Task {
            try? await app.db.write { dbc in
                try dbc.execute(sql: "UPDATE chat SET archived = NOT archived WHERE id = ?", arguments: [item.chat.id])
            }
            try? await app.api.setChatFlags(item.chat.id, archived: !item.chat.archived)
        }
    }

    func acceptRequest(_ item: ChatListItem) {
        Task {
            try? await app.api.acceptChat(item.chat.id)
            try? await app.db.write { dbc in
                try dbc.execute(sql: "UPDATE chat SET isRequest = 0, iAccepted = 1 WHERE id = ?", arguments: [item.chat.id])
            }
        }
    }

    /// Удаление чата со списка: у группы это выход из неё, у переписки —
    /// удаление своей копии. Собеседник свою сохраняет.
    func deleteChat(_ item: ChatListItem) {
        Task { await app.engine.deleteChat(chatId: item.chat.id) }
    }

    func blockRequest(_ item: ChatListItem) {
        guard let peer = item.peer else { return }
        Task {
            try? await app.engine.setBlocked(userId: peer.id, blocked: true)
            try? await app.db.write { dbc in
                try dbc.execute(sql: "DELETE FROM chat WHERE id = ?", arguments: [item.chat.id])
                try dbc.execute(sql: "DELETE FROM message WHERE chatId = ?", arguments: [item.chat.id])
            }
        }
    }
}
