import Foundation
import Combine
import GRDB
import MsngrCore

/// Элемент ленты: сообщение с флагами группировки или дата-разделитель.
/// tightGap — маленький зазор сверху (продолжение серии того же автора выше на экране);
/// showTail — хвостик баббла (последний в серии, ниже нет своего сообщения).
enum ChatFeedItem: Identifiable, Equatable {
    case message(Message, tightGap: Bool, showTail: Bool, showName: Bool, authorName: String?)
    /// id уникален в пределах ленты (label может повторяться при немонотонном sentAt)
    case dateSeparator(id: String, label: String)

    var id: String {
        switch self {
        case .message(let m, _, _, _, _): return m.id
        case .dateSeparator(let id, _): return id
        }
    }
}

@MainActor
final class ChatViewModel: ObservableObject {
    let chatId: String
    @Published var chat: Chat?
    @Published var peer: User?
    @Published var members: [User] = []
    /// лента инвертирована: [0] — самое новое
    @Published var feed: [ChatFeedItem] = []
    @Published var typingUsers: [String] = []
    @Published var replyingTo: Message?
    @Published var editing: Message?
    @Published var pinnedMessage: Message?
    @Published var keyChangePending = false
    @Published var connected = true

    private var cancellable: AnyCancellable?
    private var typingTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var typingClearTask: Task<Void, Never>?
    private let app = AppState.shared
    var ownUserId: String { app.session?.userId ?? "" }

    init(chatId: String) {
        self.chatId = chatId
    }

    /// Переподписывается после stop(): подписка пересоздаётся, если её нет.
    func start() {
        guard cancellable == nil, let db = app.db else { return }
        let chatId = self.chatId
        let ownId = ownUserId
        cancellable = ValueObservation
            .tracking { dbc -> (Chat?, [Message], [User]) in
                let chat = try Chat.fetchOne(dbc, key: chatId)
                let msgs = try Message.fetchAll(dbc, sql: """
                    SELECT * FROM message WHERE chatId = ?
                    ORDER BY COALESCE(seq, 999999999) DESC, sentAt DESC LIMIT 500
                    """, arguments: [chatId])
                let users = try User.fetchAll(dbc, sql: """
                    SELECT u.* FROM user u JOIN member m ON m.userId = u.id WHERE m.chatId = ?
                    """, arguments: [chatId])
                return (chat, msgs, users)
            }
            .publisher(in: db, scheduling: .async(onQueue: .main))
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] chat, msgs, users in
                guard let self else { return }
                self.chat = chat
                self.members = users
                self.peer = users.first { $0.id != ownId }
                self.feed = Self.buildFeed(msgs, members: users)
                if let pinId = chat?.pinnedMsgId {
                    self.pinnedMessage = msgs.first { $0.msgId == pinId }
                } else {
                    self.pinnedMessage = nil
                }
                self.markVisibleRead()
                self.refreshKeyChangePending()
            })

        connectionTask?.cancel()
        connectionTask = Task { [weak self] in
            guard let engine = self?.app.engine else { return }
            await MainActor.run { [isUp = await engine.isConnected] in self?.connected = isUp }
            let stream = await engine.connectionStream.stream
            for await up in stream {
                guard let self else { return }
                self.connected = up
            }
        }

        typingTask?.cancel()
        typingTask = Task { [weak self] in
            guard let engine = self?.app.engine else { return }
            let stream = await engine.typingStream.stream
            for await ev in stream {
                guard let self, ev.chatId == self.chatId else { continue }
                if ev.kind != nil {
                    if !self.typingUsers.contains(ev.userId) { self.typingUsers.append(ev.userId) }
                    self.typingClearTask?.cancel()
                    self.typingClearTask = Task {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        self.typingUsers.removeAll()
                    }
                } else {
                    self.typingUsers.removeAll { $0 == ev.userId }
                }
            }
        }
    }

    func stop() {
        cancellable = nil
        typingTask?.cancel()
        typingTask = nil
        connectionTask?.cancel()
        connectionTask = nil
    }

    /// TOFU: смена identity-ключа собеседника блокирует исходящие до принятия.
    private func refreshKeyChangePending() {
        guard chat?.kind == .direct, let peerId = peer?.id, let store = app.store else {
            keyChangePending = false
            return
        }
        keyChangePending = (try? store.pendingKeyChange(userId: peerId)) ?? false
    }

    func acceptKeyChange() {
        guard let peerId = peer?.id else { return }
        Task {
            await app.engine.acceptKeyChange(chatId: chatId, peerUserId: peerId)
            await MainActor.run { self.keyChangePending = false }
        }
    }

    /// Группировка бабблов + дата-разделители (лента инвертирована).
    static func buildFeed(_ msgs: [Message], members: [User]) -> [ChatFeedItem] {
        var out: [ChatFeedItem] = []
        let cal = Calendar.current
        let nameById = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.displayName) })
        let isGroupChat = members.count > 2

        func sameSeries(_ a: Message, _ b: Message) -> Bool {
            a.fromUserId == b.fromUserId && abs(a.sentAt - b.sentAt) < 60
                && cal.isDate(Date(timeIntervalSince1970: a.sentAt),
                              inSameDayAs: Date(timeIntervalSince1970: b.sentAt))
                && a.kind != .system && b.kind != .system
        }

        for (i, msg) in msgs.enumerated() {
            let newer = i > 0 ? msgs[i - 1] : nil              // ниже на экране
            let older = i + 1 < msgs.count ? msgs[i + 1] : nil // выше на экране

            // хвостик — если ниже нет своего сообщения той же серии (последний в серии снизу)
            let showTail = !(newer.map { sameSeries($0, msg) } ?? false)
            // первый в серии сверху — если выше нет своего сообщения той же серии
            let firstInSeries = !(older.map { sameSeries($0, msg) } ?? false)
            // тесный зазор сверху — когда это продолжение серии (сверху свой)
            let tightGap = !firstInSeries

            let showName = isGroupChat && !msg.isOutgoing && firstInSeries && msg.kind != .system
            out.append(.message(msg, tightGap: tightGap, showTail: showTail,
                                showName: showName,
                                authorName: nameById[msg.fromUserId] ?? "?"))
            let next = older

            // разделитель дат: перед первым сообщением дня (в инвертированной ленте — после).
            // id привязан к сообщению, а не к label: label может повторяться,
            // если sentAt немонотонен и один день встречается в ленте дважды
            let msgDay = Date(timeIntervalSince1970: msg.sentAt)
            if next == nil || !cal.isDate(Date(timeIntervalSince1970: next!.sentAt), inSameDayAs: msgDay) {
                out.append(.dateSeparator(id: "date:\(msg.id)", label: Self.dayLabel(msgDay)))
            }
        }
        return out
    }

    static func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Сегодня" }
        if cal.isDateInYesterday(date) { return "Вчера" }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "ru_RU")
        fmt.dateFormat = cal.isDate(date, equalTo: Date(), toGranularity: .year) ? "d MMMM" : "d MMMM yyyy"
        return fmt.string(from: date)
    }

    // MARK: - Заголовок

    var headerTitle: String {
        if chat?.kind == .direct { return peer?.displayName ?? "…" }
        return chat?.title ?? "Группа"
    }

    var headerSubtitle: String {
        // без соединения любой presence — стейл, не врём «в сети»
        if !connected { return "подключение…" }
        if !typingUsers.isEmpty {
            if chat?.kind == .group, let name = members.first(where: { $0.id == typingUsers[0] })?.displayName {
                return "\(name) печатает…"
            }
            return "печатает…"
        }
        if chat?.kind == .group {
            return "\(members.count) участников"
        }
        guard let peer else { return "" }
        if peer.online { return "в сети" }
        if peer.lastSeen > 0 {
            return "был(а) " + RelativeDateTimeFormatter.ruShort.localizedString(
                for: Date(timeIntervalSince1970: peer.lastSeen), relativeTo: Date())
        }
        return ""
    }

    // MARK: - Действия

    func send(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let editing {
            var c = ContentPayload(kind: "edit")
            c.targetMsgId = editing.msgId ?? editing.id
            c.text = trimmed
            Task { try? await app.engine.enqueue(content: c, chatId: chatId) }
            self.editing = nil
            return
        }
        var c = ContentPayload(kind: "text")
        c.text = trimmed
        c.replyTo = replyingTo.map {
            ReplyPreview(msgId: $0.msgId ?? $0.id, authorId: $0.fromUserId,
                         text: Self.previewText($0), kind: $0.kind.rawValue)
        }
        replyingTo = nil
        saveDraft(nil)
        Task { try? await app.engine.enqueue(content: c, chatId: chatId) }
        Haptics.light()
    }

    static func previewText(_ m: Message) -> String {
        switch m.kind {
        case .photo: return "Фото"
        case .video: return "Видео"
        case .voice: return "Голосовое сообщение"
        case .file: return m.media?.name ?? "Файл"
        case .album: return "Альбом"
        default: return String((m.text ?? "").prefix(80))
        }
    }

    func react(_ msg: Message, emoji: String) {
        var c = ContentPayload(kind: "reaction")
        c.targetMsgId = msg.msgId ?? msg.id
        // повторный тап той же реакцией — снять
        let mine = msg.reactions.first { $0.value.contains(ownUserId) }?.key
        c.emoji = (mine == emoji) ? nil : emoji
        Task { try? await app.engine.enqueue(content: c, chatId: chatId) }
        Haptics.medium()
    }

    func delete(_ msg: Message, forAll: Bool) {
        Task { await app.engine.deleteMessages(chatId: chatId, msgIds: [msg.msgId ?? msg.id], forAll: forAll) }
    }

    func forward(_ msg: Message, to targetChatId: String) {
        var c = ContentPayload(kind: msg.kind.rawValue)
        c.text = msg.text
        c.media = msg.media
        c.album = msg.album
        let fromName = members.first { $0.id == msg.fromUserId }?.displayName ?? "?"
        c.fwd = ForwardInfo(fromUserId: msg.fromUserId, fromName: fromName)
        Task { try? await app.engine.enqueue(content: c, chatId: targetChatId) }
    }

    func pin(_ msg: Message?) {
        Task { try? await app.api.pinMessage(chatId, msgId: msg?.msgId) }
    }

    func acceptRequest() {
        Task { await app.engine.acceptChatRequest(chatId: chatId) }
    }

    private var lastTypingSent = Date.distantPast

    func textChanged(_ text: String) {
        saveDraft(text.isEmpty ? nil : text)
        guard chat?.iAccepted != false else { return }
        if text.isEmpty {
            // поле опустело — снимаем «печатает…» у собеседника сразу
            lastTypingSent = .distantPast
            Task { await app.engine.sendTyping(chatId: chatId, kind: nil) }
            return
        }
        if Date().timeIntervalSince(lastTypingSent) > 3 {
            lastTypingSent = Date()
            Task { await app.engine.sendTyping(chatId: chatId, kind: "text") }
        }
    }

    func saveDraft(_ text: String?) {
        Task {
            try? await app.db.write { [chatId] dbc in
                try dbc.execute(sql: "UPDATE chat SET draft = ? WHERE id = ?", arguments: [text, chatId])
            }
        }
    }

    /// true, когда новейшие сообщения реально на экране (лента у низа).
    var isViewingBottom = true

    func markVisibleRead() {
        // не отмечаем прочтение, когда сцена не активна (фон/шторка): экран не виден
        guard !app.obscured, isViewingBottom, let chat, chat.lastSeq > chat.myReadUpTo else { return }
        Task { await app.engine.markRead(chatId: chatId, upToSeq: chat.lastSeq) }
    }

    private var loadingOlder = false

    /// Пагинация вверх: догрузка старых сообщений с сервера (если локально меньше).
    func loadOlder() {
        guard let chat, !loadingOlder else { return }
        loadingOlder = true
        Task {
            defer { loadingOlder = false }
            let minSeq = (try? await app.db.read { [chatId] dbc in
                try Int.fetchOne(dbc, sql: "SELECT MIN(seq) FROM message WHERE chatId = ? AND seq IS NOT NULL",
                                 arguments: [chatId])
            }) ?? nil
            guard let minSeq, minSeq > 1 else { return }
            guard let msgs = try? await app.api.history(chatId: chatId,
                                                        fromSeq: max(0, minSeq - 51),
                                                        toSeq: minSeq - 1, limit: 50) else { return }
            for m in msgs where m.body != nil {
                // расшифровка старой истории тем же pipeline
                let result = (try? app.e2ee.decrypt(envelopeJSON: m.body!, chatId: chatId,
                                                    fromUserId: m.from, fromDeviceId: m.fromDevice))
                if case .content(let content) = result {
                    await storeHistoric(content: content, dto: m)
                }
            }
        }
    }

    private func storeHistoric(content: ContentPayload, dto: APIClient.HistoryResponse.MsgDTO) async {
        guard !["edit", "reaction", "disappearing"].contains(content.kind) else { return }
        var msg = Message(id: dto.msgId, chatId: chatId, fromUserId: dto.from, sentAt: dto.sentAt,
                          kind: MessageKind(rawValue: content.kind) ?? .text,
                          text: content.text, status: .sent, isOutgoing: dto.from == ownUserId)
        msg.msgId = dto.msgId
        msg.seq = dto.seq
        msg.serverTs = dto.ts
        msg.media = content.media
        msg.album = content.album
        msg.replyTo = content.replyTo
        msg.forward = content.fwd
        try? await app.db.write { [msg] dbc in
            try msg.upsert(dbc)
        }
    }
}

extension RelativeDateTimeFormatter {
    static let ruShort: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.unitsStyle = .short
        return f
    }()
}
