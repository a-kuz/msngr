import Foundation
import Combine
import GRDB
import MsngrCore

/// Feed item: a message with its grouping flags, or a date separator.
/// tightGap is a narrow gap above, set when the message continues a series by the
/// same author higher up the screen; showTail draws the bubble's tail, set when
/// nothing of the same series sits below.
enum ChatFeedItem: Identifiable, Equatable {
    /// replyAuthorName is the author of the quoted message ("you" for our own),
    /// nil for messages without a quote.
    case message(Message, tightGap: Bool, showTail: Bool, showName: Bool, authorName: String?,
                 replyAuthorName: String? = nil)
    /// id is unique within the feed; label is not, because sentAt is not monotonic
    /// and the same day can appear twice.
    case dateSeparator(id: String, label: String)
    /// The unread-count banner above the first unread message.
    /// id stays stable for the whole viewing session: it is tied to the anchor seq.
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
    /// The feed is inverted: [0] is the newest item.
    @Published var feed: [ChatFeedItem] = []
    @Published private(set) var typingUsers: [String] = []
    @Published var replyingTo: Message?
    @Published var editing: Message?
    @Published var pinnedMessage: Message?
    @Published var keyChangePending = false
    @Published var connected = true
    /// Multi-select mode: checkboxes on the bubbles, an action bar in place of the input.
    @Published var selecting = false
    @Published var selection = MessageSelection()
    /// At the bottom, in place of the action bar, the confirmation for deleting the
    /// selection. The messages stay visible and more can be added to the selection.
    @Published var confirmingDelete = false
    /// The message never reached the send queue. Shown as an alert: otherwise the
    /// typed text or the attachment would vanish without a word.
    @Published var sendFailure: String?
    /// Счётчик своих отправок: каждая ведёт ленту к концу чата.
    @Published private(set) var sendTick = 0

    /// Unread banner: the state lives from the moment the chat is opened, and the
    /// feed is rebuilt from the last database snapshot whenever it changes.
    private(set) var unreadMarker = UnreadMarkerState()
    private var enteredChat = false
    /// Incoming messages up to this seq are already counted in the banner.
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
    private var typing = TypingState()
    private var presenceTask: Task<Void, Never>?
    private var presenceAsked = false
    private var typingExpiryTask: Task<Void, Never>?
    private let app = AppState.shared
    var ownUserId: String { app.session?.userId ?? "" }

    init(chatId: String) {
        self.chatId = chatId
    }

    /// Resubscribes after stop(): the subscription is recreated when it is missing.
    func start() {
        guard cancellable == nil, app.db != nil else { return }
        observeChat()

        // background or notification shade: the unread banner goes away, whatever
        // arrives meanwhile accumulates and comes back as a new banner
        obscuredCancellable = app.$obscured.removeDuplicates().dropFirst()
            .sink { [weak self] obscured in
                guard let self else { return }
                if obscured {
                    self.unreadMarker.becameObscured()
                } else {
                    self.unreadMarker.becameActive()
                    // what arrived in the background is already on screen, so send
                    // the read receipt now instead of waiting for the next db change
                    self.markVisibleRead()
                    // presence transitions that happened while the app was away
                    // never reached this device
                    self.askPresence(force: true)
                }
                self.rebuildFeed()
            }

        connectionTask?.cancel()
        connectionTask = Task { [weak self] in
            guard let engine = self?.app.engine else { return }
            // the broadcast replays the current connection state as its first element
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
                    self.typing.began(ev.userId, at: Date())
                } else if self.typing.users.contains(ev.userId) {
                    self.typing.ended(ev.userId)
                } else {
                    // a stop for someone who was not typing: every incoming message
                    // brings one
                    continue
                }
                self.typingUsers = self.typing.users
                self.scheduleTypingExpiry()
            }
        }
    }

    /// One timer, set to whoever falls out first. It is rearmed after every frame,
    /// so a cancelled one must not take anybody off the header on its way out: a
    /// peer typing without pause sends a frame every three seconds, and each one
    /// would then blink the subtitle back to the presence line.
    private func scheduleTypingExpiry() {
        typingExpiryTask?.cancel()
        guard let deadline = typing.nextExpiry() else { return }
        typingExpiryTask = Task { [weak self] in
            let wait = deadline.timeIntervalSinceNow
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            guard !Task.isCancelled, let self else { return }
            self.typing.expire(at: Date())
            self.typingUsers = self.typing.users
            self.scheduleTypingExpiry()
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
                try PerfTrace.shared.measure("feed.fetch") {
                    try Self.fetchSnapshot(dbc, chatId: chatId, ownId: ownId, floorBox: floorBox)
                }
            }
            .publisher(in: db, scheduling: .async(onQueue: .main))
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] snapshot in
                PerfTrace.shared.measure("feed.apply", info: ["msgs": Double(snapshot.msgs.count)]) {
                    self?.apply(snapshot, ownId: ownId)
                }
            })
    }

    /// One fetch of the feed observation: the window, who is in the chat, and
    /// the two flags the screen draws around it.
    private static func fetchSnapshot(_ dbc: GRDB.Database, chatId: String, ownId: String,
                                      floorBox: FeedWindow) throws -> Snapshot {
        let chat = try Chat.fetchOne(dbc, key: chatId)
        let plan = floorBox.plan()
        var floor = plan.floor
        if plan.recompute {
            floor = try HistoryWindow.newestFloor(dbc, chatId: chatId, limit: plan.capacity)
            floorBox.set(floor)
        }
        // a recomputed floor already sits `capacity` messages below the newest; a
        // floor that stays put needs the cap spelled out, or the window grows
        // with the chat
        let msgs = try HistoryWindow.messages(dbc, chatId: chatId, floor: floor,
                                              limit: plan.recompute ? nil : plan.capacity)
        let users = try User.fetchAll(dbc, sql: """
            SELECT u.* FROM user u JOIN member m ON m.userId = u.id WHERE m.chatId = ?
            """, arguments: [chatId])
        // the pending key change is read here rather than from the main thread: a
        // read of its own would block on the writer queue, and during a burst that
        // queue is busy applying messages
        // it is read over every member, not just the peer of a direct chat: in a
        // group a key change by any of them blocks sending, and without the banner
        // the message would sit there forever
        let peers = users.map(\.id).filter { $0 != ownId }
        var keyChangePending = false
        if !peers.isEmpty {
            keyChangePending = try Bool.fetchOne(dbc, sql: """
                SELECT EXISTS(SELECT 1 FROM trustedIdentity
                WHERE changedPending IS NOT NULL AND userId IN (\(databaseQuestionMarks(count: peers.count))))
                """, arguments: StatementArguments(peers)) ?? false
        }
        return Snapshot(
            chat: chat, msgs: msgs, users: users,
            unreadableSeqs: try HistoryWindow.exhaustedGapSeqs(dbc, chatId: chatId, floor: floor),
            atHistoryStart: try !HistoryWindow.hasOlder(dbc, chatId: chatId, floor: floor),
            keyChangePending: keyChangePending)
    }

    private func apply(_ snapshot: Snapshot, ownId: String) {
        chat = snapshot.chat
        members = snapshot.users
        peer = snapshot.users.first { $0.id != ownId }
        askPresence()
        updateUnreadMarker(chat: snapshot.chat, msgs: snapshot.msgs)
        lastMsgs = snapshot.msgs
        unreadableSeqs = snapshot.unreadableSeqs
        atHistoryStart = snapshot.atHistoryStart
        // a deferred decrypt may have landed a message below the window
        if !snapshot.atHistoryStart { reachedStart = false }
        feed = PerfTrace.shared.measure("feed.build", info: ["msgs": Double(snapshot.msgs.count)]) {
            Self.buildFeed(snapshot.msgs, members: snapshot.users, ownId: ownId,
                           unreadMarker: markerFeedParam, contentHidden: contentHidden,
                           unreadableSeqs: snapshot.unreadableSeqs,
                           atHistoryStart: snapshot.atHistoryStart)
        }
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
        typingExpiryTask?.cancel()
        typingExpiryTask = nil
        typing = TypingState()
        typingUsers = []
        connectionTask?.cancel()
        connectionTask = nil
        presenceTask?.cancel()
        presenceTask = nil
        presenceAsked = false
    }

    /// Where the peer is right now. Presence arrives as a transition, so a device
    /// that was not connected when the peer came online holds a row that says
    /// «был(а)» while the peer is reading. The chat asks once when it opens and
    /// again when the app comes back to the screen.
    private func askPresence(force: Bool = false) {
        guard chat?.kind == .direct, let peerId = peer?.id else { return }
        if presenceAsked && !force { return }
        presenceAsked = true
        presenceTask?.cancel()
        presenceTask = Task { [weak self] in
            guard let engine = self?.app.engine else { return }
            await engine.refreshPresence(of: [peerId])
        }
    }

    // MARK: - Unread banner

    private var markerFeedParam: (anchorSeq: Int, count: Int)? {
        guard let anchor = unreadMarker.anchorSeq, unreadMarker.isActive else { return nil }
        return (anchorSeq: anchor, count: unreadMarker.count)
    }

    /// The first snapshot of the chat sets the anchor and the initial count; after
    /// that every incoming message with a new seq bumps the count, or accumulates
    /// while the screen is not visible.
    private func updateUnreadMarker(chat: Chat?, msgs: [Message]) {
        guard let chat else { return }
        if !enteredChat {
            enteredChat = true
            unreadMarker.enterChat(unreadCount: chat.unreadCount, myReadUpTo: chat.myReadUpTo)
            // everything already on the server at that moment is in the initial count
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
        // sending anything ourselves (text, attachment, voice) dismisses the banner:
        // a new outgoing message at the bottom of the feed. Paging in old history
        // does not trigger this, it appends away from the head of the feed
        if unreadMarker.isActive, let first = msgs.first, first.isOutgoing,
           first.id != lastMsgs.first?.id, (first.seq ?? Int.max) > markerCountedUpToSeq {
            unreadMarker.dismiss()
        }
    }

    /// Rebuilds the feed from the last snapshot after the banner state changes.
    private func rebuildFeed() {
        feed = Self.buildFeed(lastMsgs, members: members, ownId: ownUserId, unreadMarker: markerFeedParam,
                              contentHidden: contentHidden, unreadableSeqs: unreadableSeqs,
                              atHistoryStart: atHistoryStart)
    }

    /// A request before it is accepted: the content is neither shown nor marked read.
    var contentHidden: Bool { ChatPrivacy.hidesContent(chat) }

    /// Sending a message or a reaction of our own dismisses the banner.
    private func dismissUnreadMarker() {
        guard unreadMarker.isActive else { return }
        unreadMarker.dismiss()
        rebuildFeed()
    }

    func acceptKeyChange() {
        Task { [chatId] in
            await app.engine.acceptKeyChange(chatId: chatId)
            await MainActor.run { self.keyChangePending = false }
        }
    }

    /// Bubble grouping, date separators and the unread banner, for the inverted
    /// feed. A chat with hidden content (a request before it is accepted) gets an
    /// empty feed: the screen shows the request card instead.
    /// unreadableSeqs are the seqs this device could not read; between two messages
    /// of the window they become a neutral placeholder, and adjacent ones collapse
    /// into a single placeholder.
    /// atHistoryStart means the window reached the oldest message on this device.
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

        // author of the quoted message: "you" for our own, otherwise a member's name
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
            let newer = i > 0 ? msgs[i - 1] : nil              // lower on screen
            let older = i + 1 < msgs.count ? msgs[i + 1] : nil // higher on screen

            // the tail goes on the last bubble of a series, the one with no message
            // of the same series below it
            let showTail = !(newer.map { sameSeries($0, msg) } ?? false)
            let firstInSeries = !(older.map { sameSeries($0, msg) } ?? false)
            let tightGap = !firstInSeries

            let showName = isGroupChat && !msg.isOutgoing && firstInSeries && msg.kind != .system
            out.append(.message(msg, tightGap: tightGap, showTail: showTail,
                                showName: showName,
                                authorName: nameById[msg.fromUserId] ?? "?",
                                replyAuthorName: msg.replyTo.map(replyAuthorName)))
            let next = older

            // unreadable seqs between this message and the next (older) one. A hole
            // at the edge of the window gets no placeholder: that is history not
            // paged in yet, not a gap
            if let older, let hi = msg.seq, let lo = older.seq, !unreadableSeqs.isEmpty {
                for run in Self.runs(of: unreadableSeqs.filter { $0 > lo && $0 < hi }).reversed() {
                    out.append(.unreadable(id: "gap:\(run.lowerBound)-\(run.upperBound)"))
                }
            }

            // the unread banner goes above the first message with seq >= the anchor,
            // which in an inverted feed means right after the oldest such message
            if let um = unreadMarker, let seq = msg.seq, seq >= um.anchorSeq,
               !((older?.seq).map { $0 >= um.anchorSeq } ?? false) {
                out.append(.unreadMarker(id: "unread:\(um.anchorSeq)", count: um.count))
            }

            // date separator before the first message of the day, which in an
            // inverted feed means after it. The id is tied to the message rather
            // than to the label: with non-monotonic sentAt the same day can show
            // up in the feed twice
            let msgDay = Date(timeIntervalSince1970: msg.sentAt)
            if next == nil || !cal.isDate(Date(timeIntervalSince1970: next!.sentAt), inSameDayAs: msgDay) {
                out.append(.dateSeparator(id: "date:\(msg.id)", label: Self.dayLabel(msgDay)))
            }
        }
        // the oldest message on the device: nothing above it can be restored
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

    // MARK: - Header

    var headerTitle: String {
        if chat?.kind == .direct { return peer?.displayName ?? "…" }
        return chat?.title ?? "Группа"
    }

    var headerSubtitle: String {
        // with no connection any presence is stale, so don't claim the peer is online
        if !connected { return "подключение…" }
        if !typingUsers.isEmpty {
            if chat?.kind == .group, let name = members.first(where: { $0.id == typingUsers[0] })?.displayName {
                return "\(name) печатает…"
            }
            return "печатает…"
        }
        if chat?.kind == .group {
            return Self.membersText(members.count)
        }
        guard let peer else { return "" }
        if peer.online { return "в сети" }
        if peer.lastSeen > 0 { return Self.lastSeenText(peer.lastSeen) }
        return ""
    }

    /// "N participants", in Russian plural forms.
    static func membersText(_ count: Int) -> String {
        let mod100 = count % 100
        let mod10 = count % 10
        let noun: String
        if mod100 / 10 == 1 {
            noun = "участников"
        } else if mod10 == 1 {
            noun = "участник"
        } else if (2...4).contains(mod10) {
            noun = "участника"
        } else {
            noun = "участников"
        }
        return "\(count) \(noun)"
    }

    /// The "last seen" line built from a timestamp. A fresh timestamp plus a server
    /// clock running ahead gives a negative difference, which the relative formatter
    /// renders as a moment in the future, so a recent departure gets its own wording.
    static func lastSeenText(_ lastSeen: TimeInterval, now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince1970 - lastSeen
        if elapsed < 60 { return "был(а) только что" }
        return "был(а) " + RelativeDateTimeFormatter.ruShort.localizedString(
            for: Date(timeIntervalSince1970: lastSeen), relativeTo: now)
    }

    // MARK: - Actions

    /// Puts content into the send queue. The queue is local and the network plays
    /// no part here: a failure means the row never made it into the database and
    /// the message is lost, which is worth telling the user about.
    func enqueue(_ content: ContentPayload, chatId: String? = nil) {
        let target = chatId ?? self.chatId
        if Self.movesFeedToEnd(kind: content.kind, target: target, chatId: self.chatId) {
            returnToBottom()
        }
        Task { [weak self] in
            do {
                try await app.engine.enqueue(content: content, chatId: target)
            } catch {
                MsngrLog.outbox.error("failed to enqueue \(content.kind): \(error)")
                self?.sendFailure = "Сообщение не отправлено: не удалось записать его на устройство"
            }
        }
    }

    func send(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        PerfTrace.shared.mark("send.tap")
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
        // tapping the same reaction again removes it
        let mine = msg.reactions.first { $0.value.contains(ownUserId) }?.key
        c.emoji = (mine == emoji) ? nil : emoji
        enqueue(c)
        Haptics.medium()
    }

    // MARK: - Multi-select

    /// Selected messages in feed order, newest first.
    var selectedMessages: [Message] { selection.messages(in: lastMsgs) }

    var canDeleteSelectedForAll: Bool { MessageSelection.canDeleteForAll(selectedMessages) }

    /// confirmingDelete — вход сразу к подтверждению удаления: сообщение
    /// выбрано, внизу два действия, а не всплывающее меню поверх самого баббла.
    func beginSelection(with msg: Message, confirmingDelete: Bool = false) {
        selection.clear()
        selection.select(msg)
        selecting = true
        self.confirmingDelete = confirmingDelete
        Haptics.light()
    }

    func toggleSelection(_ msg: Message) {
        selection.toggle(msg)
        // выбор опустел — подтверждать нечего
        if selection.isEmpty { confirmingDelete = false }
        Haptics.light()
    }

    func endSelection() {
        selecting = false
        confirmingDelete = false
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
        // the feed is in reverse order, so forward oldest to newest
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

    /// Clearing history: the messages of this chat leave the device, the chat stays.
    /// The feed window starts over, because its floor pointed at a seq whose row
    /// is gone.
    func clearHistory() {
        Task { [chatId] in
            await app.engine.clearHistory(chatId: chatId)
            windowFloor.set(nil)
            reachedStart = false
            unreadMarker.dismiss()
            observeChat()
        }
    }

    /// Deleting the chat: the screen closes and the chat leaves the device.
    func deleteChat() {
        stop()
        NotificationCenter.default.post(name: .chatDeleted, object: chatId)
        Task { [chatId] in await app.engine.deleteChat(chatId: chatId) }
    }

    /// Rejecting a request: the sender is blocked, the chat and its messages are
    /// deleted locally. A rejected request leaves the device the same way a deleted
    /// chat does: through the queue, with a tombstone. Otherwise the snapshot would
    /// bring it back, and the returning chat would start its cursors from zero.
    func blockRequest() {
        guard let peerId = peer?.id else { return }
        stop()
        Task { [chatId] in
            await app.engine.deleteChat(chatId: chatId)
            try? await app.engine.setBlocked(userId: peerId, blocked: true)
        }
    }

    private var lastTypingSent = Date.distantPast

    func textChanged(_ text: String) {
        saveDraft(text.isEmpty ? nil : text)
        guard chat?.iAccepted != false else { return }
        if text.isEmpty {
            // the field is empty again: clear the typing indicator on the other side at once
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

    /// True while the newest messages are actually on screen, that is, the feed is
    /// at the bottom. Then the window slides along with new messages; once the
    /// reader scrolls up, its floor stays put.
    var isViewingBottom = true {
        didSet { windowFloor.setAtBottom(isViewingBottom) }
    }

    func markVisibleRead() {
        // don't mark read while the scene is inactive (background, notification
        // shade): the screen is not visible
        guard !app.obscured, isViewingBottom, !contentHidden,
              let chat, chat.lastSeq > chat.myReadUpTo else { return }
        Task { await app.engine.markRead(chatId: chatId, upToSeq: chat.lastSeq) }
    }

    private var loadingOlder = false
    /// The window reached the start of local history and no seq gaps are left open:
    /// there is nothing more to scroll to, and scrolling up goes neither to the
    /// database nor to the server.
    private var reachedStart = false

    /// Paginates upwards by growing the feed window.
    func loadOlder() {
        Task { await expandWindow() }
    }

    /// The start of the chat: the window's floor moves to the oldest message the device
    /// holds, in one move. The server is not asked here — the start is what the device
    /// already stores.
    func loadDeviceHistory() async {
        guard let db = app.db else { return }
        let oldest = try? await db.read { [chatId] dbc in
            try String.fetchOne(dbc, sql: """
                SELECT id FROM message
                WHERE chatId = ? AND seq IS NOT NULL
                ORDER BY seq ASC LIMIT 1
                """, arguments: [chatId])
        }
        guard let oldest = oldest ?? nil else { return }
        _ = await anchorWindow(to: oldest)
    }

    /// The window has reached the oldest message on the device.
    var isAtDeviceStart: Bool { atHistoryStart }

    /// One page up. The messages are already decrypted and stored, so the page comes
    /// from the database; the server is only asked about an open seq gap, the part
    /// this device has never decrypted. Returns false when there is nothing to grow into.
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
        // local history is exhausted: the only thing worth asking the server for is
        // what this device has never decrypted
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

    /// The message is already in the feed, matched by server msgId or by local id.
    func isLoaded(msgId: String) -> Bool {
        lastMsgs.contains { $0.id == msgId || $0.msgId == msgId }
    }

    /// Brings a message into the feed: jumping from a quote, from the gallery or
    /// from search.
    ///
    /// A message that is already stored is reached by moving the window floor once,
    /// no matter how many thousands of messages sit between it and the end of the
    /// conversation. Paging is only needed when the move has nothing to aim at: the
    /// message has no seq, or its row is not on the device yet.
    func ensureLoaded(msgId: String, maxPages: Int = 12) async -> Bool {
        if isLoaded(msgId: msgId) { return true }
        if await anchorWindow(to: msgId), await feedContains(msgId: msgId) { return true }
        for _ in 0..<maxPages {
            guard await expandWindow() else { break }
            if await feedContains(msgId: msgId) { return true }
        }
        return isLoaded(msgId: msgId)
    }

    /// Puts the window floor on the message and stretches the capacity to the end of
    /// the conversation, so the window holds the message itself and everything newer.
    /// Returns false when there is nothing to aim at: the message is not on the
    /// device, or it has no seq.
    private func anchorWindow(to msgId: String) async -> Bool {
        guard let db = app.db else { return false }
        let current = windowFloor.get()
        let anchor = try? await db.read { [chatId] dbc -> (floor: Int, count: Int)? in
            guard let seq = try Int.fetchOne(dbc, sql: """
                SELECT seq FROM message
                WHERE chatId = ? AND (msgId = ? OR id = ?) AND seq IS NOT NULL
                """, arguments: [chatId, msgId, msgId]) else { return nil }
            // a message newer than the floor is already inside; the window is only
            // short on capacity
            let floor = min(seq, current ?? seq)
            // our own unsent messages have no seq yet and sit above everything numbered
            let count = try Int.fetchOne(dbc, sql: """
                SELECT COUNT(*) FROM message
                WHERE chatId = ? AND (seq >= ? OR seq IS NULL)
                """, arguments: [chatId, floor]) ?? 0
            return (floor, count)
        }
        guard let anchor = anchor ?? nil else { return false }
        windowFloor.anchor(floor: anchor.floor, capacity: anchor.count)
        observeChat()
        return true
    }

    /// The feed arrives from the database observation asynchronously, so wait for
    /// the message to show up.
    private func feedContains(msgId: String, attempts: Int = 20) async -> Bool {
        for _ in 0..<attempts {
            if isLoaded(msgId: msgId) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }
}

extension Notification.Name {
    /// The chat was deleted from the device: the chat list closes its screen.
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
