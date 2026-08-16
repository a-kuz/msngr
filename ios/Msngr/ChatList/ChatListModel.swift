import Foundation
import Combine
import GRDB
import MsngrCore

/// Chat list row: the chat plus the data derived for display.
struct ChatListItem: Identifiable, Equatable {
    var chat: Chat
    var peer: User?          // direct chats only
    var lastMessage: Message?
    var typingText: String?  // "печатает…"
    var id: String { chat.id }

    var title: String {
        if chat.kind == .direct { return peer?.displayName ?? "…" }
        return chat.title ?? "Группа"
    }
}

/// One observation result: the whole chat list and everything the tabs are
/// built from. Folders are read by the same observation as the chats, so the
/// list and its tabs always describe the same database state.
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
    /// Tabs above the list, in the user's order. «Все» is not a folder: it is
    /// the whole list.
    @Published var folders: [ChatFolder] = []
    /// Selected tab; nil stands for «Все».
    @Published var selectedFolderId: String?
    /// How many chats have unread in each folder; the nil tab is keyed by "".
    @Published private(set) var folderUnread: [String: Int] = [:]
    /// Folder contents: folder id to chat ids. Recomputed once per observation
    /// result, not on every tab switch.
    private var membership: [String: Set<String>] = [:]
    @Published var searchText = ""
    @Published var searchResults: [ChatListItem] = []
    /// true after the first database observation result; before that the list is loading, not empty
    @Published var loaded = false

    private var cancellable: AnyCancellable?
    private var typing: [String: (userId: String, until: Date)] = [:]
    private var typingTask: Task<Void, Never>?
    /// Per-chat timers that clear «печатает…»: without them the indicator only
    /// goes out on the next event (lazy expiry) and can stay stuck.
    private var typingClearTasks: [String: Task<Void, Never>] = [:]
    private let app = AppState.shared

    private var started = false

    func start() {
        // db is created asynchronously in bootstrap and may not be there yet on
        // a cold start; then we wait for readiness, or the list stays empty
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

        // typing from the engine
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

    // MARK: - Folders

    /// Spreads the list over the folders: one pass through the chats per folder
    /// per observation result. After that a tab switch works off ready contents.
    ///
    /// Folders are built from `items`, so archived chats and requests stay out
    /// of them: counting them in a folder as well would show the same unread
    /// twice.
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
            selectedFolderId = nil    // the folder was deleted while it was open
        }
    }

    /// Rows of a tab. The folder contents are already computed by the
    /// observation, so switching a tab walks a ready list instead of hitting
    /// the database.
    func items(in folderId: String?) -> [ChatListItem] {
        guard let folderId, let ids = membership[folderId] else { return items }
        return items.filter { ids.contains($0.id) }
    }

    /// Which folders the chat was put into by hand or landed in by rule.
    func folders(containing chatId: String) -> Set<String> {
        Set(membership.filter { $0.value.contains(chatId) }.keys)
    }

    /// What is in the folder right now, both by rule and by hand.
    func chatIds(in folder: ChatFolder) -> Set<String> { membership[folder.id] ?? [] }

    /// Saves the folder as a whole: name, rules and contents. One transaction,
    /// so the list never sees the new rules with the old contents.
    ///
    /// The contents come in as the set of chats that should end up in the
    /// folder. What the rule brings in is not stored; only the divergences are
    /// written down: a chat the rule doesn't give, and a chat the rule gives
    /// but the user took out.
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

    /// Puts the chat into a folder or takes it out. A chat taken out of a
    /// folder it matches by rule is remembered as an exclusion, otherwise the
    /// rule would bring it right back.
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

    /// Chat by id, taken from the list, the archive or the requests. A search
    /// hit row needs to know whose message it is.
    func item(for chatId: String) -> ChatListItem? {
        items.first { $0.id == chatId }
            ?? archived.first { $0.id == chatId }
            ?? requests.first { $0.id == chatId }
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

    // MARK: - Actions

    func togglePin(_ item: ChatListItem) {
        Task {
            try? await app.db.write { dbc in
                try dbc.execute(sql: "UPDATE chat SET pinned = NOT pinned WHERE id = ?", arguments: [item.chat.id])
            }
            try? await app.api.setChatFlags(item.chat.id, pinned: !item.chat.pinned)
        }
    }

    /// A swipe mutes indefinitely; the duration is picked in the chat profile.
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
