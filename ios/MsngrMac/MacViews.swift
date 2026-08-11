import SwiftUI
import GRDB
import Combine
import MsngrCore
import MsngrCrypto

// MARK: - Регистрация

struct MacRegisterView: View {
    @EnvironmentObject var app: MacAppState
    @State private var username = ""
    @State private var displayName = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "message.circle.fill").font(.system(size: 64)).foregroundStyle(.blue)
            Text("Msngr для Mac").font(.largeTitle.bold())
            TextField("Юзернейм", text: $username).frame(width: 260)
            TextField("Имя", text: $displayName).frame(width: 260)
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            Button("Создать аккаунт") {
                Task {
                    busy = true; defer { busy = false }
                    do { try await app.register(username: username, displayName: displayName) }
                    catch let e as APIError { error = e.code == "username_taken" ? "Юзернейм занят" : e.code }
                    catch { self.error = "Нет связи с сервером" }
                }
            }
            .disabled(busy || username.count < 3)
            .keyboardShortcut(.return)
        }
        .padding(40)
    }
}

// MARK: - Root split view

struct MacRootView: View {
    @EnvironmentObject var app: MacAppState
    @StateObject private var list = MacChatListModel()
    @State private var selected: String?
    @State private var showNew = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
                ForEach(list.items) { item in
                    MacChatRow(item: item).tag(item.chat.id)
                }
            }
            .navigationTitle("Чаты")
            .toolbar {
                ToolbarItem {
                    Button { showNew = true } label: { Image(systemName: "square.and.pencil") }
                }
            }
            .frame(minWidth: 260)
        } detail: {
            if let selected {
                MacChatView(chatId: selected).id(selected)
            } else {
                Text("Выберите чат").foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showNew) {
            MacNewChatView { chatId in
                showNew = false
                selected = chatId
            }
        }
        .onAppear { list.start() }
    }
}

struct MacChatRow: View {
    let item: MacChatListModel.Item

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(.blue.gradient).frame(width: 38, height: 38)
                .overlay(Text(String(item.title.prefix(1))).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).fontWeight(.semibold)
                Text(item.preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if item.chat.unreadCount > 0 {
                Text("\(item.chat.unreadCount)")
                    .font(.caption2).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.blue, in: Capsule())
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Chat list model

@MainActor
final class MacChatListModel: ObservableObject {
    struct Item: Identifiable {
        var chat: Chat
        var title: String
        var preview: String
        var id: String { chat.id }
    }
    @Published var items: [Item] = []
    private var cancellable: AnyCancellable?

    func start() {
        guard let db = MacAppStateHolder.shared?.db else { return }
        let ownId = OwnUser.id
        cancellable = ValueObservation.tracking { dbc -> [Item] in
            let chats = try Chat.fetchAll(dbc, sql: "SELECT * FROM chat ORDER BY pinned DESC, lastActivityAt DESC")
            return try chats.map { chat in
                var title = chat.title ?? "Группа"
                if chat.kind == .direct,
                   let pid = try String.fetchOne(dbc, sql: "SELECT userId FROM member WHERE chatId = ? AND userId != ?", arguments: [chat.id, ownId]),
                   let peer = try User.fetchOne(dbc, key: pid) {
                    title = peer.displayName
                }
                let last = try Message.fetchOne(dbc, sql: "SELECT * FROM message WHERE chatId = ? AND kind != 'system' ORDER BY COALESCE(serverTs,sentAt) DESC LIMIT 1", arguments: [chat.id])
                return Item(chat: chat, title: title, preview: last.map { macPreviewText($0) } ?? "")
            }
        }
        .publisher(in: db, scheduling: .async(onQueue: .main))
        .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] in self?.items = $0 })
    }

}

func macPreviewText(_ m: Message) -> String {
    switch m.kind {
    case .photo: return "📷 Фото"
    case .voice: return "🎤 Голосовое"
    case .file: return "📎 Файл"
    default: return m.text ?? ""
    }
}

/// Держатель ссылки на state для моделей (macOS не прокидывает env в ObservableObject).
enum MacAppStateHolder {
    @MainActor static var shared: MacAppState?
}

// MARK: - Chat view

struct MacChatView: View {
    let chatId: String
    @EnvironmentObject var app: MacAppState
    @StateObject private var model = MacChatModel()
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(model.messages) { m in
                            MacBubble(message: m, ownId: OwnUser.id,
                                      senderName: model.name(for: m.fromUserId))
                                .id(m.id)
                                .contextMenu {
                                    Button("❤️") { model.react(m, "❤️") }
                                    Button("👍") { model.react(m, "👍") }
                                    Button("Ответить") { model.replyingTo = m }
                                    Button("Удалить у всех", role: .destructive) { model.delete(m) }
                                }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: model.messages.count) { _, _ in
                    if let last = model.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            Divider()
            if let reply = model.replyingTo {
                HStack {
                    Text("Ответ: \(reply.text ?? "…")").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.replyingTo = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                }.padding(.horizontal, 12).padding(.top, 4)
            }
            HStack {
                TextField("Сообщение", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .onSubmit(sendText)
                    .lineLimit(1...6)
                Button(action: sendText) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(10)
        }
        .navigationTitle(model.title)
        .onAppear { model.start(chatId: chatId) }
    }

    private func sendText() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        text = ""
        model.send(text: t)
    }
}

@MainActor
final class MacChatModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var title = ""
    @Published var replyingTo: Message?
    private var cancellable: AnyCancellable?
    private var members: [String: String] = [:]
    private var chatId = ""

    func start(chatId: String) {
        self.chatId = chatId
        guard let db = MacAppStateHolder.shared?.db else { return }
        let ownId = OwnUser.id
        cancellable = ValueObservation.tracking { dbc -> ([Message], String, [String: String]) in
            let msgs = try Message.fetchAll(dbc, sql: "SELECT * FROM message WHERE chatId = ? ORDER BY COALESCE(seq, 999999999) ASC, sentAt ASC", arguments: [chatId])
            let users = try User.fetchAll(dbc, sql: "SELECT u.* FROM user u JOIN member m ON m.userId=u.id WHERE m.chatId = ?", arguments: [chatId])
            let chat = try Chat.fetchOne(dbc, key: chatId)
            var title = chat?.title ?? "Группа"
            if chat?.kind == .direct, let peer = users.first(where: { $0.id != ownId }) {
                title = peer.displayName
            }
            return (msgs, title, Dictionary(uniqueKeysWithValues: users.map { ($0.id, $0.displayName) }))
        }
        .publisher(in: db, scheduling: .async(onQueue: .main))
        .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] msgs, title, members in
            self?.messages = msgs
            self?.title = title
            self?.members = members
            self?.markRead()
        })
    }

    func name(for id: String) -> String { members[id] ?? "?" }

    func send(text: String) {
        var c = ContentPayload(kind: "text")
        c.text = text
        if let r = replyingTo {
            c.replyTo = ReplyPreview(msgId: r.msgId ?? r.id, authorId: r.fromUserId,
                                     text: String((r.text ?? "").prefix(60)), kind: r.kind.rawValue)
        }
        replyingTo = nil
        Task { try? await MacAppStateHolder.shared?.engine.enqueue(content: c, chatId: chatId) }
    }

    func react(_ m: Message, _ emoji: String) {
        var c = ContentPayload(kind: "reaction")
        c.targetMsgId = m.msgId ?? m.id
        let mine = m.reactions.first { $0.value.contains(OwnUser.id) }?.key
        c.emoji = (mine == emoji) ? nil : emoji
        Task { try? await MacAppStateHolder.shared?.engine.enqueue(content: c, chatId: chatId) }
    }

    func delete(_ m: Message) {
        Task { await MacAppStateHolder.shared?.engine.deleteMessages(chatId: chatId, msgIds: [m.msgId ?? m.id], forAll: true) }
    }

    private func markRead() {
        guard let last = messages.last?.seq else { return }
        Task { await MacAppStateHolder.shared?.engine.markRead(chatId: chatId, upToSeq: last) }
    }
}

struct MacBubble: View {
    let message: Message
    let ownId: String
    let senderName: String

    private var isOut: Bool { message.isOutgoing }

    var body: some View {
        HStack {
            if isOut { Spacer(minLength: 60) }
            VStack(alignment: isOut ? .trailing : .leading, spacing: 2) {
                if let reply = message.replyTo {
                    Text(reply.text).font(.caption2).foregroundStyle(.secondary)
                        .padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
                if message.kind == .system {
                    Text(systemText).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    HStack(alignment: .bottom, spacing: 6) {
                        Text(message.deletedForAll ? "Сообщение удалено" : (message.text ?? mediaLabel))
                            .textSelection(.enabled)
                        Text(time).font(.caption2).foregroundStyle(.secondary)
                        if isOut { statusIcon }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(isOut ? Color.green.opacity(0.25) : Color.gray.opacity(0.18),
                                in: RoundedRectangle(cornerRadius: 14))
                }
                if !message.reactions.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(message.reactions.sorted(by: { $0.key < $1.key }), id: \.key) { emoji, users in
                            Text(users.count > 1 ? "\(emoji) \(users.count)" : emoji)
                                .font(.caption)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }
            if !isOut { Spacer(minLength: 60) }
        }
    }

    private var mediaLabel: String {
        switch message.kind {
        case .photo: return "📷 Фото"
        case .video: return "🎥 Видео"
        case .voice: return "🎤 Голосовое сообщение"
        case .file: return "📎 " + (message.media?.name ?? "Файл")
        case .album: return "🖼 Альбом"
        default: return ""
        }
    }

    private var systemText: String {
        let t = message.text ?? ""
        if t.hasPrefix("identity_changed:") { return "Код безопасности изменился" }
        if t == "undecryptable" { return "Не удалось расшифровать" }
        return t
    }

    private var time: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: message.serverTs ?? message.sentAt))
    }

    private var statusIcon: some View {
        Image(systemName: {
            switch message.status {
            case .failed: return "exclamationmark"
            case .sending: return "clock"
            case .sent: return "checkmark"
            case .delivered, .read: return "checkmark.circle"
            }
        }())
        .font(.caption2)
        .foregroundStyle(message.status == .read ? .green : .secondary)
    }
}

struct MacNewChatView: View {
    var onOpen: (String) -> Void
    @EnvironmentObject var app: MacAppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [APIClient.UserDTO] = []

    var body: some View {
        VStack {
            TextField("Юзернейм", text: $query)
                .onChange(of: query) { _, q in
                    Task { results = q.count >= 2 ? ((try? await app.api.searchUsers(q)) ?? []) : [] }
                }
            List(results, id: \.id) { u in
                Button {
                    Task {
                        if let chatId = try? await app.api.createChat(kind: "direct", memberIds: [u.id], title: nil) {
                            try? await app.engine.refreshSnapshot()
                            onOpen(chatId)
                        }
                    }
                } label: {
                    HStack {
                        Text(u.display_name).fontWeight(.medium)
                        Text("@\(u.username)").foregroundStyle(.secondary)
                    }
                }
            }
            Button("Закрыть") { dismiss() }
        }
        .padding()
        .frame(width: 360, height: 400)
    }
}
