import Foundation
import Combine
import GRDB
import MsngrCore

/// Feed item: a message with its grouping flags, or a date separator.
/// tightGap is a narrow gap above, set when the message continues a series by the
/// same author higher up the screen; showTail draws the bubble's tail, set when
/// nothing of the same series sits below.
/// The sender behind an incoming group bubble. Its presence reserves the avatar
/// column in the layout; the picture itself is drawn on the last message of a
/// run (the one with the tail), the ones above leave the space empty.
struct FeedAvatar: Equatable {
    let userId: String
    let name: String
    let avatarId: String?
}

enum ChatFeedItem: Identifiable, Equatable {
    /// replyAuthorName is the author of the quoted message ("you" for our own),
    /// nil for messages without a quote. avatar is non-nil only for incoming
    /// messages in group chats.
    case message(Message, tightGap: Bool, showTail: Bool, showName: Bool, authorName: String?,
                 replyAuthorName: String? = nil, avatar: FeedAvatar? = nil)
    /// id is unique within the feed; label is not, because sentAt is not monotonic
    /// and the same day can appear twice.
    case dateSeparator(id: String, label: String)
    /// The unread-count banner above the first unread message.
    /// id stays stable for the whole viewing session: it is tied to the anchor seq.
    case unreadMarker(id: String, count: Int)
    /// Messages this device could not read, between two messages of the feed.
    /// Neighbouring seqs collapse into one item.
    case unreadable(id: String)

    var id: String {
        switch self {
        case .message(let m, _, _, _, _, _, _): return m.id
        case .dateSeparator(let id, _): return id
        case .unreadMarker(let id, _): return id
        case .unreadable(let id): return id
        }
    }
}

@MainActor
final class ChatViewModel: ObservableObject {
    let chatId: String
    @Published var chat: Chat?
    @Published var peer: User?
    @Published var members: [User] = []
    /// My role in this chat; nil while it is being read or once I am out of it.
    @Published var myRole: String?
    /// The feed is inverted: [0] is the newest item.
    @Published var feed: [ChatFeedItem] = []
    @Published private(set) var typingUsers: [String] = []
    @Published var replyingTo: Message?
    @Published var editing: Message?
    /// The pinned rows in pin order, the newest pin last.
    @Published var pinnedMessages: [Message] = []
    /// Which pin the bar shows: an index into `pinnedMessages`. Reset to the
    /// newest whenever the set changes; walking the bar moves it backwards.
    @Published var pinnedFocus = 0
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
    /// My send counter: each one scrolls the feed to the end of the chat.
    @Published private(set) var sendTick = 0
    /// Unread messages that mention you: the «@» button over the feed and
    /// where its tap lands. nil while nothing unread mentions you.
    @Published private(set) var unreadMentions: (count: Int, earliestId: String)?

    /// Unread banner: the state lives from the moment the chat is opened, and the
    /// feed is rebuilt from the last database snapshot whenever it changes.
    private(set) var unreadMarker = UnreadMarkerState()
    private var enteredChat = false
    /// Incoming messages up to this seq are already counted in the banner.
    private var markerCountedUpToSeq = 0
    /// lastSeq the banner count was last derived for; a row emission past it re-derives.
    private var markerReconciledLastSeq = 0
    /// The chat's lastSeq at the moment the screen went away, for the return banner.
    private var obscuredAtLastSeq = 0
    private var lastMsgs: [Message] = []
    private var obscuredCancellable: AnyCancellable?
    private var pinCancellable: AnyCancellable?
    /// The pinnedSeqs the pin observation is installed for.
    private var observedPinSeqs: [Int] = []

    /// Seq of messages inside the window this device could not read.
    private var unreadableSeqs: [Int] = []
    /// The window covers the oldest message stored for this chat.
    private var atHistoryStart = false
    /// The window reaches the newest message of the chat. False after a jump into the
    /// history: the top of the feed is then a message with the rest of the conversation
    /// above it, so nothing there counts as read and the screen keeps offering the way
    /// back down.
    @Published private(set) var atNewest = true

    private let windowFloor = FeedWindow()

    /// One fetch of the feed observation.
    private struct Snapshot {
        let msgs: [Message]
        let users: [User]
        let myRole: String?
        let unreadableSeqs: [Int]
        let atHistoryStart: Bool
        let atNewest: Bool
        /// TOFU: the peer's identity key changed and was not accepted yet.
        let keyChangePending: Bool
    }

    private var cancellable: AnyCancellable?
    private var chatCancellable: AnyCancellable?
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
        guard chatCancellable == nil, app.db != nil else { return }
        observeChatRow()

        // background or notification shade: the unread banner goes away, whatever
        // arrives meanwhile accumulates and comes back as a new banner
        obscuredCancellable = app.$obscured.removeDuplicates().dropFirst()
            .sink { [weak self] obscured in
                guard let self else { return }
                if obscured {
                    self.obscuredAtLastSeq = self.chat?.lastSeq ?? 0
                    self.unreadMarker.becameObscured()
                } else {
                    self.unreadMarker.becameActive()
                    self.restoreMarkerAfterObscured()
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

    /// The chat row on its own. Everything the screen draws around the feed — the
    /// header, the unread count, the pin, the draft — comes from here, and the feed
    /// fetch does not read the row at all: a keystroke writing the draft, an arriving
    /// envelope moving `lastSeq` and a peer's read receipt all land on this one row,
    /// and inside the window fetch each of them re-read, rebuilt and re-diffed the
    /// whole feed.
    /// Recounts the unread mentions of this user whenever the chat row moves:
    /// a new message and a read receipt both come through it.
    private func refreshUnreadMentions(_ chat: Chat?) {
        guard let chat, chat.unreadCount > 0, let db = app.db else {
            if unreadMentions != nil { unreadMentions = nil }
            return
        }
        let ownId = ownUserId
        Task { [weak self] in
            let found = try? await db.read { dbc in
                try MentionMarks.unreadMentions(dbc, chatId: chat.id,
                                                myReadUpTo: chat.myReadUpTo, ownUserId: ownId)
            }
            await MainActor.run {
                guard let self else { return }
                if self.unreadMentions?.count != found?.count
                    || self.unreadMentions?.earliestId != found?.earliestId {
                    self.unreadMentions = found ?? nil
                }
            }
        }
    }

    private func observeChatRow() {
        guard let db = app.db else { return }
        let chatId = self.chatId
        chatCancellable = ValueObservation
            .tracking { dbc in try Chat.fetchOne(dbc, key: chatId) }
            .publisher(in: db, scheduling: .async(onQueue: .main))
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] chat in
                self?.applyChat(chat)
            })
    }

    /// The chat row arrived. The feed observation is installed from here, on the first
    /// one: the unread banner is built out of the row, and a feed drawn before the row
    /// is known would have to be rebuilt with the banner right after.
    private func applyChat(_ chat: Chat?) {
        let wasHidden = contentHidden
        self.chat = chat
        if let chat, !enteredChat {
            enteredChat = true
            unreadMarker.enterChat(unreadCount: chat.unreadCount, myReadUpTo: chat.myReadUpTo)
            // everything already on the server at that moment is in the initial count
            markerCountedUpToSeq = chat.lastSeq
            // the banner owns the landing when there is unread; otherwise the feed
            // goes back to where the reader left off last time
            if chat.unreadCount == 0 { publishSavedReadingPosition() }
        }
        if let chat { reconcileUnreadMarker(chat) }
        refreshUnreadMentions(chat)
        if cancellable == nil {
            observeChat()
        } else if contentHidden != wasHidden {
            rebuildFeed()
        }
        observePinnedMessage()
        markVisibleRead()
    }

    /// Installs the feed observation for the current window floor. Growing the
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
        let myRole = try String.fetchOne(
            dbc, sql: "SELECT role FROM member WHERE chatId = ? AND userId = ?",
            arguments: [chatId, ownId])
        // a window filled to its capacity may have been cut short of the end of the
        // conversation; a shorter one took everything above the floor there was
        var atNewest = plan.recompute || msgs.count < plan.capacity
        if !atNewest {
            atNewest = try !HistoryWindow.hasNewer(dbc, chatId: chatId, topSeq: msgs.first?.seq)
        }
        return Snapshot(
            msgs: msgs, users: users, myRole: myRole,
            unreadableSeqs: try HistoryWindow.exhaustedGapSeqs(dbc, chatId: chatId, floor: floor),
            atHistoryStart: try !HistoryWindow.hasOlder(dbc, chatId: chatId, floor: floor),
            atNewest: atNewest,
            keyChangePending: keyChangePending)
    }

    private func apply(_ snapshot: Snapshot, ownId: String) {
        members = snapshot.users
        myRole = snapshot.myRole
        peer = snapshot.users.first { $0.id != ownId }
        askPresence()
        countIncoming(snapshot.msgs)
        lastMsgs = snapshot.msgs
        unreadableSeqs = snapshot.unreadableSeqs
        atHistoryStart = snapshot.atHistoryStart
        atNewest = snapshot.atNewest
        // a jump that landed near the end of the chat holds the newest message anyway,
        // so the window is free to follow it again
        if snapshot.atNewest { windowFloor.releaseAnchor() }
        // a deferred decrypt may have landed a message below the window
        if !snapshot.atHistoryStart { reachedStart = false }
        feed = PerfTrace.shared.measure("feed.build", info: ["msgs": Double(snapshot.msgs.count)]) {
            Self.buildFeed(snapshot.msgs, members: snapshot.users, ownId: ownId,
                           unreadMarker: markerFeedParam, contentHidden: contentHidden,
                           unreadableSeqs: snapshot.unreadableSeqs)
        }
        keyChangePending = snapshot.keyChangePending
        markVisibleRead()
    }

    /// The pinned message rows on their own, looked up by the chat row's
    /// pinnedSeqs. The feed window plays no part here: pins thousands of
    /// messages deep are one read on the (chatId, seq) unique index, and an
    /// edit or a deletion of any of those rows re-emits through the
    /// observation. The rows come back in pin order, the newest pin last.
    private func observePinnedMessage() {
        let pinSeqs = chat?.pinnedSeqs ?? []
        guard !pinSeqs.isEmpty, !contentHidden else {
            observedPinSeqs = []
            pinCancellable = nil
            pinnedMessages = []
            return
        }
        guard pinSeqs != observedPinSeqs, let db = app.db else { return }
        observedPinSeqs = pinSeqs
        let chatId = self.chatId
        pinCancellable = ValueObservation
            .tracking { dbc -> [Message] in
                let marks = pinSeqs.map { _ in "?" }.joined(separator: ",")
                let rows = try Message.fetchAll(dbc, sql: """
                    SELECT * FROM message WHERE chatId = ? AND seq IN (\(marks))
                    """, arguments: StatementArguments([chatId] + pinSeqs.map(String.init)))
                let bySeq = Dictionary(uniqueKeysWithValues: rows.compactMap { m in m.seq.map { ($0, m) } })
                return pinSeqs.compactMap { bySeq[$0] }
            }
            .publisher(in: db, scheduling: .async(onQueue: .main))
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] msgs in
                guard let self else { return }
                self.pinnedMessages = msgs
                self.pinnedFocus = max(0, msgs.count - 1)
            })
    }

    func stop() {
        cancellable = nil
        chatCancellable = nil
        obscuredCancellable = nil
        pinCancellable = nil
        observedPinSeqs = []
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

    /// The chat row sets the anchor and the initial count when the screen opens; after
    /// that every incoming message with a new seq bumps the count, or accumulates
    /// while the screen is not visible.
    private func countIncoming(_ msgs: [Message]) {
        guard enteredChat else { return }
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

    /// The banner's count is derived, not incremented: catch-up appends rows the
    /// feed window never shows, and coalesced emissions skip seqs, so counting
    /// snapshot rows loses arrivals. Whenever the chat row's lastSeq moves past
    /// what was last derived, the database says how many incoming messages stand
    /// at or after the anchor.
    private func reconcileUnreadMarker(_ chat: Chat) {
        guard unreadMarker.isActive, let anchor = unreadMarker.anchorSeq,
              chat.lastSeq > markerReconciledLastSeq, let db = app.db else { return }
        markerReconciledLastSeq = chat.lastSeq
        let chatId = self.chatId
        Task { [weak self] in
            let n = (try? await db.read { dbc in
                try Self.incomingCount(dbc, chatId: chatId, fromSeq: anchor)
            }) ?? 0
            guard let self, self.unreadMarker.isActive,
                  self.unreadMarker.anchorSeq == anchor else { return }
            let before = self.unreadMarker.count
            self.unreadMarker.reconcile(incomingSinceAnchor: n)
            if self.unreadMarker.count != before { self.rebuildFeed() }
        }
    }

    /// Back from the background or the shade: what arrived while away becomes a
    /// banner counted from the database, whether or not any of it ever passed
    /// through a feed window snapshot.
    private func restoreMarkerAfterObscured() {
        guard let chat, let db = app.db else { return }
        markerReconciledLastSeq = 0
        if unreadMarker.isActive {
            reconcileUnreadMarker(chat)
            return
        }
        let since = obscuredAtLastSeq
        guard chat.lastSeq > since else { return }
        let chatId = self.chatId
        Task { [weak self] in
            let found = try? await db.read { dbc in
                try Self.firstArrival(dbc, chatId: chatId, after: since)
            }
            guard let self, let found,
                  !self.app.obscured, !self.unreadMarker.isActive else { return }
            self.unreadMarker.plant(anchorSeq: found.firstSeq, count: found.count)
            self.rebuildFeed()
        }
    }

    /// Incoming messages at or after the banner's anchor.
    nonisolated static func incomingCount(_ dbc: GRDB.Database, chatId: String, fromSeq: Int) throws -> Int {
        try Int.fetchOne(dbc, sql: """
            SELECT COUNT(*) FROM message
            WHERE chatId = ? AND isOutgoing = 0 AND seq >= ?
            """, arguments: [chatId, fromSeq]) ?? 0
    }

    /// The first incoming message after the given seq and how many followed it.
    nonisolated static func firstArrival(_ dbc: GRDB.Database, chatId: String,
                             after seq: Int) throws -> (firstSeq: Int, count: Int)? {
        let row = try Row.fetchOne(dbc, sql: """
            SELECT COUNT(*) AS n, MIN(seq) AS first FROM message
            WHERE chatId = ? AND isOutgoing = 0 AND seq > ?
            """, arguments: [chatId, seq])
        guard let row, let n = row["n"] as Int?, n > 0,
              let first = row["first"] as Int? else { return nil }
        return (firstSeq: first, count: n)
    }

    // MARK: - The reading position between openings

    /// Where the reader stood when the chat was last left; the screen scrolls
    /// there once, on entry with nothing unread.
    @Published private(set) var restoreSeq: Int?
    private var restoreSuppressed = false

    /// An explicit jump (search, a push) owns the landing; the stored position yields.
    func suppressRestore() { restoreSuppressed = true }

    /// Called on leaving the chat: the seq the reader was looking at, or nil at
    /// the bottom, which clears the stored position.
    func saveReadingPosition(_ seq: Int?) {
        guard let db = app.db else { return }
        let chatId = self.chatId
        Task {
            try? await db.write { dbc in
                try Self.storeReadingPosition(dbc, chatId: chatId, seq: seq)
            }
        }
    }

    private func publishSavedReadingPosition() {
        guard !restoreSuppressed, let db = app.db else { return }
        let chatId = self.chatId
        Task { [weak self] in
            let seq = try? await db.read { dbc in
                try Self.readingPosition(dbc, chatId: chatId)
            }
            guard let self, let seq else { return }
            self.restoreSeq = seq
        }
    }

    nonisolated static func storeReadingPosition(_ dbc: GRDB.Database, chatId: String,
                                                 seq: Int?) throws {
        let key = "feedpos:\(chatId)"
        if let seq {
            try KVRow(key: key, value: String(seq)).save(dbc)
        } else {
            try dbc.execute(sql: "DELETE FROM kv WHERE key = ?", arguments: [key])
        }
    }

    nonisolated static func readingPosition(_ dbc: GRDB.Database, chatId: String) throws -> Int? {
        try String.fetchOne(dbc, sql: "SELECT value FROM kv WHERE key = ?",
                            arguments: ["feedpos:\(chatId)"]).flatMap(Int.init)
    }

    /// Rebuilds the feed from the last snapshot after the banner state changes.
    private func rebuildFeed() {
        feed = Self.buildFeed(lastMsgs, members: members, ownId: ownUserId, unreadMarker: markerFeedParam,
                              contentHidden: contentHidden, unreadableSeqs: unreadableSeqs)
    }

    /// A request before it is accepted: the content is neither shown nor marked read.
    var contentHidden: Bool { ChatPrivacy.hidesContent(chat) && !acceptedLocally }
    @Published private(set) var acceptedLocally = false

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
    static func buildFeed(_ msgs: [Message], members: [User], ownId: String = "",
                          unreadMarker: (anchorSeq: Int, count: Int)? = nil,
                          contentHidden: Bool = false,
                          unreadableSeqs: [Int] = []) -> [ChatFeedItem] {
        guard !contentHidden else { return [] }
        var out: [ChatFeedItem] = []
        let cal = Calendar.current
        let nameById = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.displayName) })
        let avatarIdById = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.avatarId) })
        let isGroupChat = members.count > 2

        // author of the quoted message: "you" for our own, otherwise a member's name
        func replyAuthorName(_ reply: ReplyPreview) -> String {
            reply.authorId == ownId ? String(localized: "You") : (nameById[reply.authorId] ?? "?")
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
            // every incoming group message reserves the avatar column; whether the
            // picture is drawn in it follows showTail (the last message of the run)
            let avatar: FeedAvatar? = isGroupChat && !msg.isOutgoing && msg.kind != .system
                ? FeedAvatar(userId: msg.fromUserId,
                             name: nameById[msg.fromUserId] ?? "?",
                             avatarId: avatarIdById[msg.fromUserId] ?? nil)
                : nil
            out.append(.message(msg, tightGap: tightGap, showTail: showTail,
                                showName: showName,
                                authorName: nameById[msg.fromUserId] ?? "?",
                                replyAuthorName: msg.replyTo.map(replyAuthorName),
                                avatar: avatar))
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
        if cal.isDateInToday(date) { return String(localized: "Today") }
        if cal.isDateInYesterday(date) { return String(localized: "Yesterday") }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "ru_RU")
        fmt.dateFormat = cal.isDate(date, equalTo: Date(), toGranularity: .year) ? "d MMMM" : "d MMMM yyyy"
        return fmt.string(from: date)
    }

    // MARK: - Header

    var headerTitle: String {
        switch chat?.kind {
        case .direct: return peer?.displayName ?? "…"
        case .saved: return String(localized: "Saved Messages")
        case .group, nil: return chat?.title ?? String(localized: "Group")
        }
    }

    var isSavedChat: Bool { chat?.kind == .saved }
    var avatarGlyph: String? { isSavedChat ? AvatarStyle.savedGlyph : nil }

    var headerSubtitle: String {
        if !connected { return String(localized: "connecting…") }
        if !typingUsers.isEmpty {
            if chat?.kind == .group, let name = members.first(where: { $0.id == typingUsers[0] })?.displayName {
                return "\(name) " + String(localized: "typing…")
            }
            return String(localized: "typing…")
        }
        if chat?.kind == .group {
            return Self.membersText(members.count)
        }
        guard let peer else { return "" }
        if peer.online { return String(localized: "online") }
        if peer.lastSeen > 0 { return Self.lastSeenText(peer.lastSeen) }
        return ""
    }

    var headerSubtitleAccented: Bool {
        !typingUsers.isEmpty || (peer?.online ?? false)
    }

    static func membersText(_ count: Int) -> String {
        String(localized: "\(count) participants")
    }

    static func lastSeenText(_ lastSeen: TimeInterval, now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince1970 - lastSeen
        if elapsed < 60 { return String(localized: "last seen just now") }
        let relTime = RelativeDateTimeFormatter.short.localizedString(
            for: Date(timeIntervalSince1970: lastSeen), relativeTo: now)
        return String(localized: "last seen \(relTime)")
    }

    // MARK: - Rights

    private var kind: ChatKind { chat?.kind ?? .direct }

    /// Whether this chat takes my messages at all. A group whose rights are set
    /// to admins is read-only for everyone else, and the input field gives way
    /// to a note instead of standing there disabled.
    var canSend: Bool {
        ChatPermissions.canSend(kind: kind, role: myRole,
                                sendPolicy: chat?.sendPolicy ?? ChatPermissions.openPolicy)
    }

    /// My own display name, as the other members see it: it goes into the group
    /// events I publish.
    var ownDisplayName: String {
        members.first { $0.id == ownUserId }?.displayName ?? ""
    }

    /// Publishes a group event from me. Service content: no unread, no push, a
    /// system line in the feed.
    func announce(_ verb: GroupEvent.Verb, member: String? = nil, memberId: String? = nil,
                  text: String? = nil) {
        let event = GroupEvent(verb: verb, actor: ownDisplayName, member: member,
                               memberId: memberId, text: text)
        Task { [chatId] in await app.engine?.announce(event, chatId: chatId) }
    }

    // MARK: - Actions

    /// Puts content into the send queue. The queue is local and the network plays
    /// no part here: a failure means the row never made it into the database and
    /// the message is lost, which is worth telling the user about.
    func enqueue(_ content: ContentPayload, chatId: String? = nil) {
        let target = chatId ?? self.chatId
        if Self.movesFeedToEnd(kind: content.kind, target: target, chatId: self.chatId) {
            returnToBottom()
            sendTick &+= 1
        }
        Task { [weak self] in
            do {
                try await app.engine.enqueue(content: content, chatId: target)
            } catch {
                MsngrLog.outbox.error("failed to enqueue \(content.kind): \(error)")
                self?.sendFailure = String(localized: "Failed to save message")
            }
        }
    }

    /// Puts a media placeholder into the feed before the attachment is ready:
    /// the row is visible and takes the same "move the feed to the bottom"
    /// path as `enqueue`, but nothing is sent until the caller fills it in
    /// with `updateMediaPreview`/`updateAlbumItemPreview` and moves it into
    /// the outbox with `finalizeMedia`.
    func beginMedia(clientMsgId: String, kind: MessageKind, text: String?,
                    media: MediaInfo?, album: [MediaInfo]?) async {
        if Self.movesFeedToEnd(kind: kind.rawValue, target: chatId, chatId: chatId) {
            returnToBottom()
            sendTick &+= 1
        }
        do {
            try await app.engine.beginMedia(clientMsgId: clientMsgId, chatId: chatId, kind: kind,
                                            text: text, media: media, album: album)
        } catch {
            MsngrLog.outbox.error("failed to begin media \(kind.rawValue): \(error)")
            sendFailure = String(localized: "Failed to save message")
        }
    }

    func resend(_ msg: Message) {
        Task { [weak self] in
            guard let self else { return }
            let queued = await self.app.engine.retrySend(messageId: msg.id)
            if !queued { self.sendFailure = String(localized: "Cannot send this message anymore") }
        }
    }

    func send(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        PerfTrace.shared.mark("send.tap")
        dismissUnreadMarker()
        let tokenized = MessageMarkdown.tokenizeMentions(trimmed, users: mentionCandidates)
        if let editing {
            var c = ContentPayload(kind: "edit")
            c.targetLocalId = editing.id
            c.text = tokenized
            enqueue(c)
            self.editing = nil
            return
        }
        var c = ContentPayload(kind: "text")
        c.text = tokenized
        c.replyTo = replyingTo.map {
            ReplyPreview(seq: $0.seq, authorId: $0.fromUserId,
                         text: Self.previewText($0), kind: $0.kind.rawValue)
        }
        replyingTo = nil
        saveDraft(nil, immediately: true)
        enqueue(c)
        Haptics.light()
    }

    /// Whom a typed "@handle" may resolve to: everyone in the chat but yourself.
    var mentionCandidates: [MessageMarkdown.MentionCandidate] {
        members.compactMap { user in
            guard user.id != ownUserId, !user.username.isEmpty else { return nil }
            return MessageMarkdown.MentionCandidate(userId: user.id, username: user.username,
                                                    displayName: user.displayName)
        }
    }

    /// Members matching the "@prefix" the field ends with; empty when the text
    /// ends with no open handle. The panel above the input runs on this.
    func mentionSuggestions(for text: String) -> [MessageMarkdown.MentionCandidate] {
        guard let at = text.lastIndex(of: "@") else { return [] }
        // the "@" must start a word, and everything after it must be handle characters
        if at > text.startIndex {
            let before = text[text.index(before: at)]
            guard !(before.isLetter || before.isNumber || before == "_") else { return [] }
        }
        let prefix = String(text[text.index(after: at)...]).lowercased()
        guard prefix.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return [] }
        return mentionCandidates.filter {
            prefix.isEmpty || $0.username.lowercased().hasPrefix(prefix)
                || $0.displayName.lowercased().hasPrefix(prefix)
        }
    }

    nonisolated static func movesFeedToEnd(kind: String, target: String, chatId: String) -> Bool {
        target == chatId && !SyncEngine.serviceKinds.contains(kind)
    }

    static func previewText(_ m: Message) -> String {
        switch m.kind {
        case .photo: return String(localized: "Photo")
        case .video: return String(localized: "Video")
        case .voice: return String(localized: "Voice message")
        case .file: return m.media?.name ?? String(localized: "File")
        case .album: return String(localized: "Album")
        case .shader: return m.shader?.name ?? String(localized: "Shader")
        default: return String(MessageMarkdown.mentionsStripped(m.text ?? "").prefix(80))
        }
    }

    func react(_ msg: Message, emoji: String) {
        dismissUnreadMarker()
        var c = ContentPayload(kind: "reaction")
        c.targetLocalId = msg.id
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

    func beginSelection(with msg: Message, confirmingDelete: Bool = false) {
        selection.clear()
        selection.select(msg)
        selecting = true
        self.confirmingDelete = confirmingDelete
        Haptics.light()
    }

    func toggleSelection(_ msg: Message) {
        selection.toggle(msg)
        if selection.isEmpty { confirmingDelete = false }
        Haptics.light()
    }

    func endSelection() {
        selecting = false
        confirmingDelete = false
        selection.clear()
    }

    func deleteSelected(forAll: Bool) {
        let ids = selectedMessages.map(\.id)
        guard !ids.isEmpty else { return }
        endSelection()
        Task { await app.engine.deleteMessages(chatId: chatId, ids: ids, forAll: forAll) }
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
        let fromName = members.first { $0.id == msg.fromUserId }?.displayName ?? "?"
        enqueue(Self.forwardPayload(msg, authorName: fromName), chatId: targetChatId)
    }

    /// What a forward carries: the content, the quote as the preview it already
    /// is, and the original author — forwarding a forward keeps pointing at
    /// whoever wrote the message, not at the middleman. Reactions stay behind:
    /// they belong to the conversation they were made in (docs/protocol.md).
    nonisolated static func forwardPayload(_ msg: Message, authorName: String) -> ContentPayload {
        var c = ContentPayload(kind: msg.kind.rawValue)
        c.text = msg.text
        c.media = msg.media
        c.album = msg.album
        c.replyTo = msg.replyTo
        c.shader = msg.shader
        c.fwd = msg.forward ?? ForwardInfo(fromUserId: msg.fromUserId, fromName: authorName)
        return c
    }

    /// Pins one more message, or takes every pin off with nil. The chat row is
    /// written on the spot and the server is told through the action queue, so
    /// the bar changes before the answer comes back.
    func pin(_ msg: Message?) {
        Task { [chatId] in await app.engine.pinMessage(chatId: chatId, seq: msg?.seq) }
    }

    /// Takes one pin off, leaving the others in place.
    func unpin(_ msg: Message) {
        guard let seq = msg.seq else { return }
        Task { [chatId] in await app.engine.pinMessage(chatId: chatId, seq: seq, pinned: false) }
    }

    /// The card gives way to the feed in the caller's transaction: the flag flips
    /// here, on the spot, and the database row follows.
    func acceptRequest() {
        acceptedLocally = true
        rebuildFeed()
        Task { await app.engine.acceptChatRequest(chatId: chatId) }
    }

    /// Clearing history: the messages of this chat leave the device, the chat stays.
    /// The feed window starts over, because its floor pointed at a seq whose row
    /// is gone.
    func clearHistory() {
        Task { [chatId] in
            await app.engine.clearHistory(chatId: chatId)
            windowFloor.reset()
            reachedStart = false
            unreadMarker.dismiss()
            observeChat()
        }
    }

    /// Deleting the chat: the screen closes and the chat leaves the device.
    /// Leaving a group is announced first and the announcement is waited for:
    /// once the membership is gone the server refuses the frame, and the others
    /// would never learn who left.
    func deleteChat() {
        let leaving = chat?.kind == .group
        let event = GroupEvent(verb: .left, actor: ownDisplayName)
        stop()
        NotificationCenter.default.post(name: .chatDeleted, object: chatId)
        Task { [chatId] in
            if leaving { await app.engine?.announce(event, chatId: chatId, waitForSend: true) }
            await app.engine.deleteChat(chatId: chatId)
        }
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

    /// The draft follows the typing at a distance. It lives on the chat row, and the
    /// chat list re-reads its rows on every write to that table, so a write per
    /// keystroke would put the whole list through a fetch five times a word.
    /// Leaving the screen and sending write it out at once: what the field holds then
    /// is the answer, and nothing may be left waiting for a timer.
    func saveDraft(_ text: String?, immediately: Bool = false) {
        draftTask?.cancel()
        guard !immediately else {
            writeDraft(text)
            return
        }
        draftTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.writeDraft(text)
        }
    }

    private func writeDraft(_ text: String?) {
        Task {
            try? await app.db.write { [chatId] dbc in
                try dbc.execute(sql: "UPDATE chat SET draft = ? WHERE id = ?", arguments: [text, chatId])
            }
        }
    }

    private var draftTask: Task<Void, Never>?

    /// True while the newest messages are actually on screen, that is, the feed is
    /// at the bottom. Then the window slides along with new messages; once the
    /// reader scrolls up, its floor stays put. Coming back down also gives the pages
    /// paged in on the way up back, and the feed is refetched on the page-sized window
    /// instead of waiting for the next write to do it.
    var isViewingBottom = true {
        didSet {
            if windowFloor.setAtBottom(isViewingBottom) { observeChat() }
        }
    }

    /// Back to the newest messages: the window leaves the history it was standing in
    /// and comes back to a page at the end of the chat. Both the scroll-down button
    /// and a send of our own go through here — a window standing in the history holds
    /// its capacity upwards from its floor, so in a chat that has since piled up that
    /// many messages the new outgoing one does not fall into the window at all.
    func returnToBottom() {
        windowFloor.reset()
        reachedStart = false
        isViewingBottom = true
        observeChat()
    }

    func markVisibleRead() {
        // don't mark read while the scene is inactive (background, notification
        // shade): the screen is not visible
        // a window standing in the history has the rest of the conversation above its
        // top, and none of that was seen
        guard !app.obscured, isViewingBottom, atNewest, !contentHidden,
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
            try Int.fetchOne(dbc, sql: """
                SELECT seq FROM message
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

    /// The message is already in the feed, matched by its local row id.
    func isLoaded(id: String) -> Bool {
        lastMsgs.contains { $0.id == id }
    }

    /// The message is already in the feed, matched by its seq.
    func isLoaded(seq: Int) -> Bool {
        lastMsgs.contains { $0.seq == seq }
    }

    /// Brings a message into the feed: jumping from the gallery or from search.
    ///
    /// A message that is already stored is reached by moving the window floor once,
    /// no matter how many thousands of messages sit between it and the end of the
    /// conversation. Paging is only needed when the move has nothing to aim at: the
    /// message has no seq, or its row is not on the device yet.
    func ensureLoaded(id: String, maxPages: Int = 12) async -> Bool {
        if isLoaded(id: id) { return true }
        let seq = (try? await app.db?.read { [chatId] dbc in
            try Int.fetchOne(dbc, sql: "SELECT seq FROM message WHERE chatId = ? AND id = ?",
                             arguments: [chatId, id])
        }) ?? nil
        if let seq, await anchorWindow(to: seq), await feedContains(where: { $0.id == id }) {
            return true
        }
        for _ in 0..<maxPages {
            guard await expandWindow() else { break }
            if await feedContains(where: { $0.id == id }) { return true }
        }
        return isLoaded(id: id)
    }

    /// Same, for a reference that names the message by its seq (a quote, a pin).
    func ensureLoaded(seq: Int, maxPages: Int = 12) async -> Bool {
        if isLoaded(seq: seq) { return true }
        if await anchorWindow(to: seq), await feedContains(where: { $0.seq == seq }) {
            return true
        }
        for _ in 0..<maxPages {
            guard await expandWindow() else { break }
            if await feedContains(where: { $0.seq == seq }) { return true }
        }
        return isLoaded(seq: seq)
    }

    /// Puts the window on the message: the floor lands a page below it and the capacity
    /// holds it with history on either side. The window stops at that, however many
    /// thousands of messages the chat has piled up since — the way back down is the
    /// scroll-down button, which returns the window to the end of the chat.
    /// Returns false when there is nothing to aim at: the message is not on the
    /// device.
    private func anchorWindow(to seq: Int) async -> Bool {
        guard let db = app.db else { return false }
        let anchor = try? await db.read { [chatId] dbc -> Int? in
            guard try Bool.fetchOne(dbc, sql: """
                SELECT EXISTS(SELECT 1 FROM message WHERE chatId = ? AND seq = ?)
                """, arguments: [chatId, seq]) == true else { return nil }
            return try HistoryWindow.floorBelow(dbc, chatId: chatId, floor: seq,
                                                limit: FeedWindow.anchorBelow) ?? seq
        }
        guard let floor = anchor ?? nil else { return false }
        windowFloor.anchor(floor: floor)
        observeChat()
        return true
    }

    /// The feed arrives from the database observation asynchronously, so wait for
    /// the message to show up.
    private func feedContains(where match: (Message) -> Bool, attempts: Int = 20) async -> Bool {
        for _ in 0..<attempts {
            if lastMsgs.contains(where: match) { return true }
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
    static let short: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}
