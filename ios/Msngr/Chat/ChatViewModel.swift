import Foundation
import Combine
import GRDB
import MsngrCore

/// Элемент ленты: сообщение с флагами группировки или дата-разделитель.
/// tightGap — маленький зазор сверху (продолжение серии того же автора выше на экране);
/// showTail — хвостик баббла (последний в серии, ниже нет своего сообщения).
enum ChatFeedItem: Identifiable, Equatable {
    /// replyAuthorName — имя автора цитируемого сообщения («Вы» для своих),
    /// nil у сообщений без цитаты.
    case message(Message, tightGap: Bool, showTail: Bool, showName: Bool, authorName: String?,
                 replyAuthorName: String? = nil)
    /// id уникален в пределах ленты (label может повторяться при немонотонном sentAt)
    case dateSeparator(id: String, label: String)
    /// плашка «N непрочитанных сообщений» над первым непрочитанным;
    /// id стабилен в пределах сессии просмотра (привязан к якорному seq)
    case unreadMarker(id: String, count: Int)
    /// Messages this device could not read, between two messages of the feed.
    /// Neighbouring seqs collapse into one item.
    case unreadable(id: String)
    /// The oldest message stored on this device: the ratchet is forward-only,
    /// so nothing above it can be restored.
    case historyStart(id: String)

    var id: String {
        switch self {
        case .message(let m, _, _, _, _, _): return m.id
        case .dateSeparator(let id, _): return id
        case .unreadMarker(let id, _): return id
        case .unreadable(let id): return id
        case .historyStart(let id): return id
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
    /// Режим мультивыбора: чекбоксы у бабблов, панель действий вместо поля ввода.
    @Published var selecting = false
    @Published var selection = MessageSelection()
    /// Сообщение не попало в очередь отправки: показывается алертом, иначе
    /// набранный текст или вложение исчезли бы молча.
    @Published var sendFailure: String?
    /// Счётчик своих отправок: каждая ведёт ленту к концу чата.
    @Published private(set) var sendTick = 0

    /// Плашка непрочитанных: состояние живёт от входа в чат, лента
    /// перестраивается при его изменении из последнего снапшота БД.
    private(set) var unreadMarker = UnreadMarkerState()
    private var enteredChat = false
    /// seq, до которого входящие уже учтены счётчиком плашки
    private var markerCountedUpToSeq = 0
    private var lastMsgs: [Message] = []
    private var obscuredCancellable: AnyCancellable?

    /// Seq of messages inside the window this device could not read.
    private var unreadableSeqs: [Int] = []
    /// The window covers the oldest message stored for this chat.
    private var atHistoryStart = false

    private let windowFloor = FeedWindow()

    /// One fetch of the chat observation.
    private struct Snapshot {
        let chat: Chat?
        let msgs: [Message]
        let users: [User]
        let unreadableSeqs: [Int]
        let atHistoryStart: Bool
        /// TOFU: the peer's identity key changed and was not accepted yet.
        let keyChangePending: Bool
    }

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
        guard cancellable == nil, app.db != nil else { return }
        observeChat()

        // фон/шторка: плашка непрочитанных убирается, пришедшее за время
        // отсутствия копится и показывается новой плашкой при возврате
        obscuredCancellable = app.$obscured.removeDuplicates().dropFirst()
            .sink { [weak self] obscured in
                guard let self else { return }
                if obscured {
                    self.unreadMarker.becameObscured()
                } else {
                    self.unreadMarker.becameActive()
                    // пришедшее в фоне уже на экране — read receipt шлём сразу,
                    // не дожидаясь следующего изменения БД
                    self.markVisibleRead()
                }
                self.rebuildFeed()
            }

        connectionTask?.cancel()
        connectionTask = Task { [weak self] in
            guard let engine = self?.app.engine else { return }
            // broadcast первым элементом отдаёт текущее состояние соединения
            for await up in engine.connectionStream.subscribe() {
                guard let self else { return }
                self.connected = up
            }
        }

        typingTask?.cancel()
        typingTask = Task { [weak self] in
            guard let engine = self?.app.engine else { return }
            for await ev in engine.typingStream.subscribe() {
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

    /// Installs the chat observation for the current window floor. Growing the
    /// window means a new floor and a fresh observation: the fetch is what
    /// carries the floor into SQL.
    private func observeChat() {
        guard let db = app.db else { return }
        let chatId = self.chatId
        let ownId = ownUserId
        let floorBox = windowFloor
        cancellable = ValueObservation
            .tracking { dbc -> Snapshot in
                let chat = try Chat.fetchOne(dbc, key: chatId)
                let plan = floorBox.plan()
                var floor = plan.floor
                if plan.recompute {
                    floor = try HistoryWindow.newestFloor(dbc, chatId: chatId,
                                                          limit: plan.capacity)
                    floorBox.set(floor)
                }
                // a recomputed floor already sits `capacity` messages below the
                // newest; a floor that stays put needs the cap spelled out, or
                // the window grows with the chat
                let msgs = try HistoryWindow.messages(dbc, chatId: chatId, floor: floor,
                                                      limit: plan.recompute ? nil : plan.capacity)
                let users = try User.fetchAll(dbc, sql: """
                    SELECT u.* FROM user u JOIN member m ON m.userId = u.id WHERE m.chatId = ?
                    """, arguments: [chatId])
                // the pending key change is read here rather than from the main
                // thread: a read of its own would block on the writer queue,
                // and during a burst that queue is busy applying messages
                var keyChangePending = false
                if chat?.kind == .direct, let peerId = users.first(where: { $0.id != ownId })?.id {
                    keyChangePending = try Row.fetchOne(
                        dbc, sql: "SELECT changedPending FROM trustedIdentity WHERE userId = ?",
                        arguments: [peerId]).map { ($0["changedPending"] as String?) != nil } ?? false
                }
                return Snapshot(
                    chat: chat, msgs: msgs, users: users,
                    unreadableSeqs: try HistoryWindow.exhaustedGapSeqs(dbc, chatId: chatId, floor: floor),
                    atHistoryStart: try !HistoryWindow.hasOlder(dbc, chatId: chatId, floor: floor),
                    keyChangePending: keyChangePending)
            }
            .publisher(in: db, scheduling: .async(onQueue: .main))
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] snapshot in
                self?.apply(snapshot, ownId: ownId)
            })
    }

    private func apply(_ snapshot: Snapshot, ownId: String) {
        chat = snapshot.chat
        members = snapshot.users
        peer = snapshot.users.first { $0.id != ownId }
        updateUnreadMarker(chat: snapshot.chat, msgs: snapshot.msgs)
        lastMsgs = snapshot.msgs
        unreadableSeqs = snapshot.unreadableSeqs
        atHistoryStart = snapshot.atHistoryStart
        // отложенная расшифровка могла положить сообщение ниже окна
        if !snapshot.atHistoryStart { reachedStart = false }
        feed = Self.buildFeed(snapshot.msgs, members: snapshot.users, ownId: ownId,
                              unreadMarker: markerFeedParam, contentHidden: contentHidden,
                              unreadableSeqs: snapshot.unreadableSeqs,
                              atHistoryStart: snapshot.atHistoryStart)
        if let pinId = snapshot.chat?.pinnedMsgId, !contentHidden {
            pinnedMessage = snapshot.msgs.first { $0.msgId == pinId }
        } else {
            pinnedMessage = nil
        }
        keyChangePending = snapshot.keyChangePending
        markVisibleRead()
    }

    func stop() {
        cancellable = nil
        obscuredCancellable = nil
        typingTask?.cancel()
        typingTask = nil
        connectionTask?.cancel()
        connectionTask = nil
    }

    // MARK: - Плашка непрочитанных

    private var markerFeedParam: (anchorSeq: Int, count: Int)? {
        guard let anchor = unreadMarker.anchorSeq, unreadMarker.isActive else { return nil }
        return (anchorSeq: anchor, count: unreadMarker.count)
    }

    /// Первый снапшот чата задаёт якорь и стартовый счётчик; дальше входящие
    /// с новым seq увеличивают счётчик (или копятся, пока экран не виден).
    private func updateUnreadMarker(chat: Chat?, msgs: [Message]) {
        guard let chat else { return }
        if !enteredChat {
            enteredChat = true
            unreadMarker.enterChat(unreadCount: chat.unreadCount, myReadUpTo: chat.myReadUpTo)
            // всё, что уже есть на сервере на момент входа, учтено стартовым счётчиком
            markerCountedUpToSeq = chat.lastSeq
            return
        }
        let newIncoming = msgs
            .compactMap { m -> Int? in m.isOutgoing ? nil : m.seq }
            .filter { $0 > markerCountedUpToSeq }
            .sorted()
        for seq in newIncoming {
            unreadMarker.incoming(seq: seq)
            markerCountedUpToSeq = seq
        }
        // своя отправка любым путём (текст, вложение, голосовое): новое
        // исходящее внизу ленты убирает плашку. Догрузка старой истории сюда
        // не попадает — она добавляет сообщения не в начало ленты
        if unreadMarker.isActive, let first = msgs.first, first.isOutgoing,
           first.id != lastMsgs.first?.id, (first.seq ?? Int.max) > markerCountedUpToSeq {
            unreadMarker.dismiss()
        }
    }

    /// Перестройка ленты из последнего снапшота при изменении состояния плашки.
    private func rebuildFeed() {
        feed = Self.buildFeed(lastMsgs, members: members, ownId: ownUserId, unreadMarker: markerFeedParam,
                              contentHidden: contentHidden, unreadableSeqs: unreadableSeqs,
                              atHistoryStart: atHistoryStart)
    }

    /// Заявка до принятия: содержимое не показываем и не отмечаем прочитанным.
    var contentHidden: Bool { ChatPrivacy.hidesContent(chat) }

    /// Своя отправка или реакция убирает плашку.
    private func dismissUnreadMarker() {
        guard unreadMarker.isActive else { return }
        unreadMarker.dismiss()
        rebuildFeed()
    }

    func acceptKeyChange() {
        guard let peerId = peer?.id else { return }
        Task {
            await app.engine.acceptKeyChange(chatId: chatId, peerUserId: peerId)
            await MainActor.run { self.keyChangePending = false }
        }
    }

    /// Группировка бабблов + дата-разделители + плашка непрочитанных
    /// (лента инвертирована). У чата со скрытым содержимым (заявка до принятия)
    /// лента пустая: вместо неё экран показывает карточку заявки.
    /// unreadableSeqs — seq, которые устройство прочитать не смогло: между двумя
    /// сообщениями окна они дают нейтральную заглушку, соседние собираются в одну.
    /// atHistoryStart — окно дошло до самого старого сообщения на устройстве.
    static func buildFeed(_ msgs: [Message], members: [User], ownId: String = "",
                          unreadMarker: (anchorSeq: Int, count: Int)? = nil,
                          contentHidden: Bool = false,
                          unreadableSeqs: [Int] = [],
                          atHistoryStart: Bool = false) -> [ChatFeedItem] {
        guard !contentHidden else { return [] }
        var out: [ChatFeedItem] = []
        let cal = Calendar.current
        let nameById = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.displayName) })
        let isGroupChat = members.count > 2

        // автор цитируемого сообщения: «Вы» для своих, имя из участников иначе
        func replyAuthorName(_ reply: ReplyPreview) -> String {
            reply.authorId == ownId ? "Вы" : (nameById[reply.authorId] ?? "?")
        }

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
                                authorName: nameById[msg.fromUserId] ?? "?",
                                replyAuthorName: msg.replyTo.map(replyAuthorName)))
            let next = older

            // нечитаемые seq между этим сообщением и следующим (более старым):
            // дыра на краю окна заглушки не получает — это ещё не догруженный низ
            if let older, let hi = msg.seq, let lo = older.seq, !unreadableSeqs.isEmpty {
                for run in Self.runs(of: unreadableSeqs.filter { $0 > lo && $0 < hi }).reversed() {
                    out.append(.unreadable(id: "gap:\(run.lowerBound)-\(run.upperBound)"))
                }
            }

            // плашка непрочитанных — над первым сообщением с seq >= якоря
            // (в инвертированной ленте — сразу после самого старого такого)
            if let um = unreadMarker, let seq = msg.seq, seq >= um.anchorSeq,
               !((older?.seq).map { $0 >= um.anchorSeq } ?? false) {
                out.append(.unreadMarker(id: "unread:\(um.anchorSeq)", count: um.count))
            }

            // разделитель дат: перед первым сообщением дня (в инвертированной ленте — после).
            // id привязан к сообщению, а не к label: label может повторяться,
            // если sentAt немонотонен и один день встречается в ленте дважды
            let msgDay = Date(timeIntervalSince1970: msg.sentAt)
            if next == nil || !cal.isDate(Date(timeIntervalSince1970: next!.sentAt), inSameDayAs: msgDay) {
                out.append(.dateSeparator(id: "date:\(msg.id)", label: Self.dayLabel(msgDay)))
            }
        }
        // самое старое, что есть на устройстве: выше история не восстанавливается
        if atHistoryStart, !out.isEmpty { out.append(.historyStart(id: "history-start")) }
        return out
    }

    /// Consecutive numbers grouped into ranges, ascending.
    static func runs(of seqs: [Int]) -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        for seq in seqs.sorted() {
            if let last = out.last, seq == last.upperBound + 1 {
                out[out.count - 1] = last.lowerBound...seq
            } else if out.last?.contains(seq) != true {
                out.append(seq...seq)
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
        if peer.lastSeen > 0 { return Self.lastSeenText(peer.lastSeen) }
        return ""
    }

    /// «был(а) …» из отметки времени. Свежая отметка и часы сервера, ушедшие
    /// вперёд, дают отрицательную разницу — относительный формат превращал её
    /// в «через 0 сек.», поэтому у недавнего выхода свой текст.
    static func lastSeenText(_ lastSeen: TimeInterval, now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince1970 - lastSeen
        if elapsed < 60 { return "был(а) только что" }
        return "был(а) " + RelativeDateTimeFormatter.ruShort.localizedString(
            for: Date(timeIntervalSince1970: lastSeen), relativeTo: now)
    }

    // MARK: - Действия

    /// Кладёт контент в очередь отправки. Очередь локальная, сеть здесь не
    /// участвует: отказ означает, что запись не легла в базу и сообщение
    /// потеряно, — о таком сообщаем пользователю.
    func enqueue(_ content: ContentPayload, chatId: String? = nil) {
        let target = chatId ?? self.chatId
        if Self.movesFeedToEnd(kind: content.kind, target: target, chatId: self.chatId) {
            returnToBottom()
        }
        Task { [weak self] in
            do {
                try await app.engine.enqueue(content: content, chatId: target)
            } catch {
                MsngrLog.outbox.error("не удалось поставить \(content.kind) в очередь: \(error)")
                self?.sendFailure = "Сообщение не отправлено: не удалось записать его на устройство"
            }
        }
    }

    func send(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        dismissUnreadMarker()
        if let editing {
            var c = ContentPayload(kind: "edit")
            c.targetMsgId = editing.msgId ?? editing.id
            c.text = trimmed
            enqueue(c)
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
        enqueue(c)
        Haptics.light()
    }

    /// Отправка, у которой в этом чате появляется свой баббл: только она ведёт
    /// ленту к концу. Правка, реакция и пересылка в другой чат — нет.
    nonisolated static func movesFeedToEnd(kind: String, target: String, chatId: String) -> Bool {
        target == chatId && !SyncEngine.serviceKinds.contains(kind)
    }

    /// Своя отправка возвращает ленту к концу чата.
    ///
    /// Окно ленты, замершее на прочитанной истории, держит ровно `capacity`
    /// сообщений вверх от своей границы: в чате, где выше границы уже набралось
    /// столько сообщений, новое исходящее в окно не попадает и на экране не
    /// появляется вовсе. Поэтому граница окна снова начинает скользить за
    /// новейшими, а лента получает счётчик отправок, по которому уезжает вниз.
    private func returnToBottom() {
        isViewingBottom = true
        sendTick &+= 1
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
        dismissUnreadMarker()
        var c = ContentPayload(kind: "reaction")
        c.targetMsgId = msg.msgId ?? msg.id
        // повторный тап той же реакцией — снять
        let mine = msg.reactions.first { $0.value.contains(ownUserId) }?.key
        c.emoji = (mine == emoji) ? nil : emoji
        enqueue(c)
        Haptics.medium()
    }

    func delete(_ msg: Message, forAll: Bool) {
        Task { await app.engine.deleteMessages(chatId: chatId, msgIds: [msg.msgId ?? msg.id], forAll: forAll) }
    }

    // MARK: - Мультивыбор

    /// Выбранные сообщения в порядке ленты (сверху — самое новое).
    var selectedMessages: [Message] { selection.messages(in: lastMsgs) }

    var canDeleteSelectedForAll: Bool { MessageSelection.canDeleteForAll(selectedMessages) }

    func beginSelection(with msg: Message) {
        selection.clear()
        selection.select(msg)
        selecting = true
        Haptics.light()
    }

    func toggleSelection(_ msg: Message) {
        selection.toggle(msg)
        Haptics.light()
    }

    func endSelection() {
        selecting = false
        selection.clear()
    }

    func deleteSelected(forAll: Bool) {
        let ids = selectedMessages.map { $0.msgId ?? $0.id }
        guard !ids.isEmpty else { return }
        endSelection()
        Task { await app.engine.deleteMessages(chatId: chatId, msgIds: ids, forAll: forAll) }
    }

    func copySelected() {
        MessageClipboard.copy(selectedMessages)
        endSelection()
    }

    func forwardSelected(to targetChatId: String) {
        // порядок ленты обратный: пересылаем от старого к новому
        for msg in selectedMessages.reversed() { forward(msg, to: targetChatId) }
        endSelection()
    }

    func forward(_ msg: Message, to targetChatId: String) {
        var c = ContentPayload(kind: msg.kind.rawValue)
        c.text = msg.text
        c.media = msg.media
        c.album = msg.album
        let fromName = members.first { $0.id == msg.fromUserId }?.displayName ?? "?"
        c.fwd = ForwardInfo(fromUserId: msg.fromUserId, fromName: fromName)
        enqueue(c, chatId: targetChatId)
    }

    func pin(_ msg: Message?) {
        Task { try? await app.api.pinMessage(chatId, msgId: msg?.msgId) }
    }

    func acceptRequest() {
        Task { await app.engine.acceptChatRequest(chatId: chatId) }
    }

    /// Очистка истории: сообщения этого чата уходят с устройства, чат остаётся.
    /// Окно ленты начинается заново — его нижняя граница указывала на seq,
    /// строки которого больше нет.
    func clearHistory() {
        Task { [chatId] in
            await app.engine.clearHistory(chatId: chatId)
            windowFloor.set(nil)
            reachedStart = false
            unreadMarker.dismiss()
            observeChat()
        }
    }

    /// Удаление чата: экран закрывается, чат уходит с устройства.
    func deleteChat() {
        stop()
        NotificationCenter.default.post(name: .chatDeleted, object: chatId)
        Task { [chatId] in await app.engine.deleteChat(chatId: chatId) }
    }

    /// Отклонение заявки: отправитель в блок, чат и его сообщения удаляются локально.
    func blockRequest() {
        guard let peerId = peer?.id else { return }
        stop()
        Task { [chatId] in
            try? await app.api.setBlocked(peerId, blocked: true)
            try? await app.db.write { dbc in
                try dbc.execute(sql: "DELETE FROM chat WHERE id = ?", arguments: [chatId])
                try dbc.execute(sql: "DELETE FROM message WHERE chatId = ?", arguments: [chatId])
            }
        }
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
    /// Пока лента у низа, окно скользит вслед за новыми сообщениями; стоит
    /// пользователю уйти вверх — нижняя граница окна замирает.
    var isViewingBottom = true {
        didSet { windowFloor.setAtBottom(isViewingBottom) }
    }

    func markVisibleRead() {
        // не отмечаем прочтение, когда сцена не активна (фон/шторка): экран не виден
        guard !app.obscured, isViewingBottom, !contentHidden,
              let chat, chat.lastSeq > chat.myReadUpTo else { return }
        Task { await app.engine.markRead(chatId: chatId, upToSeq: chat.lastSeq) }
    }

    private var loadingOlder = false
    /// Окно дошло до начала локальной истории, незакрытых разрывов seq нет:
    /// дальше листать нечего, и скролл вверх ни к базе, ни к серверу не идёт.
    private var reachedStart = false

    /// Пагинация вверх: расширение окна ленты.
    func loadOlder() {
        Task { await expandWindow() }
    }

    /// Одна страница вверх. Сообщения уже расшифрованы и лежат в базе, поэтому
    /// страница берётся из неё; к серверу уходит только незакрытый разрыв seq —
    /// то, что это устройство ещё не расшифровывало. false — расширять нечего.
    @discardableResult
    private func expandWindow() async -> Bool {
        guard chat != nil, !loadingOlder, !reachedStart, let db = app.db else { return false }
        loadingOlder = true
        defer { loadingOlder = false }
        let floor = windowFloor.get()
        if let floor {
            let next = try? await db.read { [chatId] dbc in
                try HistoryWindow.floorBelow(dbc, chatId: chatId, floor: floor,
                                             limit: HistoryWindow.pageSize)
            }
            if let next = next ?? nil, next < floor {
                windowFloor.set(next)
                windowFloor.grow(by: HistoryWindow.pageSize)
                observeChat()
                return true
            }
        }
        // локальная история исчерпана: с сервера полезно только то, что это
        // устройство ещё не расшифровывало
        let gaps = (try? await db.read { [chatId] dbc in
            try HistoryWindow.openGaps(dbc, chatId: chatId)
        }) ?? []
        guard let gap = gaps.last else {
            reachedStart = true
            return false
        }
        guard await app.engine.fillHistoryGap(chatId: chatId, from: gap.lowerBound,
                                              to: gap.upperBound) else { return false }
        windowFloor.set(min(floor ?? gap.lowerBound, gap.lowerBound))
        windowFloor.grow(by: gap.count)
        observeChat()
        return true
    }

    /// Сообщение уже в ленте (по серверному msgId или локальному id).
    func isLoaded(msgId: String) -> Bool {
        lastMsgs.contains { $0.id == msgId || $0.msgId == msgId }
    }

    /// Расширяет окно страницами, пока сообщение не окажется в ленте:
    /// переход по цитате к оригиналу за пределами окна.
    func ensureLoaded(msgId: String, maxPages: Int = 12) async -> Bool {
        if isLoaded(msgId: msgId) { return true }
        for _ in 0..<maxPages {
            guard await expandWindow() else { break }
            // лента приходит из наблюдения БД асинхронно — ждём появления сообщения
            for _ in 0..<20 {
                if isLoaded(msgId: msgId) { return true }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        return isLoaded(msgId: msgId)
    }
}

extension Notification.Name {
    /// Чат удалён с устройства: список чатов закрывает его экран.
    static let chatDeleted = Notification.Name("chatDeleted")
}

extension RelativeDateTimeFormatter {
    static let ruShort: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.unitsStyle = .short
        return f
    }()
}
