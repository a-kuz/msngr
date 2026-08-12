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

@MainActor
final class ChatListModel: ObservableObject {
    @Published var items: [ChatListItem] = []
    @Published var requests: [ChatListItem] = []
    @Published var archived: [ChatListItem] = []
    @Published var searchText = ""
    @Published var searchResults: [ChatListItem] = []

    private var cancellable: AnyCancellable?
    private var typing: [String: (userId: String, until: Date)] = [:]
    private var typingTask: Task<Void, Never>?
    private let app = AppState.shared

    private var started = false

    func start() {
        // db создаётся асинхронно в bootstrap; при холодном старте он может быть
        // ещё не готов — тогда ждём готовности, иначе список останется пустым
        guard !started, let db = app.db else { return }
        started = true
        let ownId = app.session?.userId ?? ""
        cancellable = ValueObservation
            .tracking { dbc -> ([Chat], [String: User], [String: Message]) in
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
                return (chats, peers, lasts)
            }
            .publisher(in: db, scheduling: .async(onQueue: .main))
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] chats, peers, lasts in
                guard let self else { return }
                let all = chats.map { chat in
                    ChatListItem(chat: chat, peer: peers[chat.id], lastMessage: lasts[chat.id],
                                 typingText: self.typingLabel(chat.id, peers[chat.id]))
                }
                self.requests = all.filter { $0.chat.isRequest }
                self.archived = all.filter { $0.chat.archived && !$0.chat.isRequest }
                self.items = all.filter { !$0.chat.archived && !$0.chat.isRequest }
                self.updateSearch()
            })

        // typing из engine
        typingTask?.cancel()
        typingTask = Task { [weak self] in
            guard let engine = self?.app.engine else { return }
            let stream = await engine.typingStream.stream
            for await ev in stream {
                guard let self else { return }
                if ev.kind != nil {
                    self.typing[ev.chatId] = (ev.userId, Date().addingTimeInterval(5))
                } else {
                    self.typing.removeValue(forKey: ev.chatId)
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

    func toggleMute(_ item: ChatListItem) {
        Task {
            try? await app.db.write { dbc in
                try dbc.execute(sql: "UPDATE chat SET muted = NOT muted WHERE id = ?", arguments: [item.chat.id])
            }
            try? await app.api.setChatFlags(item.chat.id, muted: !item.chat.muted)
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

    func blockRequest(_ item: ChatListItem) {
        guard let peer = item.peer else { return }
        Task {
            try? await app.api.setBlocked(peer.id, blocked: true)
            try? await app.db.write { dbc in
                try dbc.execute(sql: "DELETE FROM chat WHERE id = ?", arguments: [item.chat.id])
                try dbc.execute(sql: "DELETE FROM message WHERE chatId = ?", arguments: [item.chat.id])
            }
        }
    }
}
