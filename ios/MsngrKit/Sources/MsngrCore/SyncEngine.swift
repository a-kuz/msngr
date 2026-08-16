import CryptoKit
import Foundation
import GRDB
import MsngrCrypto

/// Orchestrator: socket ↔ database ↔ E2EE. The UI never waits on the network,
/// it reads the database only.
public actor SyncEngine {
    public let db: DatabaseQueue
    public let api: APIClient
    public let e2ee: E2EEManager
    private let media: MediaManager?
    private let ws: WSClient
    public let ownUserId: String
    public let ownDeviceId: String

    private var eventTask: Task<Void, Never>?
    private var outboxTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    /// periodic background passes: expired mutes and the unreadable queue
    private var maintenanceTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var outboxWakeup = AsyncStream<Void>.makeStream()
    private var actionWakeup = AsyncStream<Void>.makeStream()
    private var connected = false

    /// typing events are never stored, they go straight to UI subscribers
    public nonisolated let typingStream = Broadcast<(chatId: String, userId: String, kind: String?)>()
    /// connection state for the UI (the "connecting…" subtitle instead of stale
    /// presence); a subscriber gets the current state immediately
    public nonisolated let connectionStream = Broadcast<Bool>(initial: false)
    /// The device is detached from the account (its token was revoked). No
    /// reconnect will help, so the app takes the user back to registration.
    public nonisolated let sessionRevokedStream = Broadcast<Void>()
    /// The server no longer serves this build's protocol version. Reconnecting
    /// changes nothing, so the app states that it has to be updated. The
    /// refusal comes on the first upgrade, before the app has subscribed, so
    /// the stream replays it to whoever subscribes next.
    public nonisolated let protocolOutdatedStream = Broadcast<Void>(replayLast: true)

    /// A message the socket delivered for the first time: what in-app banners run on.
    public struct IncomingMessage: Sendable {
        public let chatId: String
        public let msgId: String
        public let fromUserId: String
        /// service frame (skd/edit/reaction/disappearing)
        public let isService: Bool
        /// our own message echoed back from another device
        public let isOwn: Bool
    }
    public nonisolated let incomingMessageStream = Broadcast<IncomingMessage>()

    public init(db: DatabaseQueue, api: APIClient, e2ee: E2EEManager, media: MediaManager? = nil,
                wsURL: URL, ownUserId: String, ownDeviceId: String) {
        self.db = db
        self.api = api
        self.e2ee = e2ee
        self.media = media
        self.ws = WSClient(url: wsURL)
        self.ownUserId = ownUserId
        self.ownDeviceId = ownDeviceId
    }

    // MARK: - Lifecycle

    public func start() async {
        // sends killed before their ack (state='inflight') go back into the queue;
        // the server deduplicates the possible repeat by clientMsgId. Those waiting
        // for their target's ack ('waiting') are retried in the same place: by now
        // the target may have gone out, or failed for good
        try? await db.write { dbc in
            try dbc.execute(sql: "UPDATE outbox SET state = 'ready' WHERE state IN ('inflight', 'waiting')")
        }
        let events = await ws.events()
        await ws.start()
        eventTask = Task { [weak self] in
            for await ev in events {
                guard let self else { return }
                await self.handle(ev)
            }
        }
        outboxTask = Task { [weak self] in
            guard let self else { return }
            for await _ in await self.outboxWakeup.stream {
                await self.drainOutbox()
            }
        }
        actionTask = Task { [weak self] in
            guard let self else { return }
            for await _ in await self.actionWakeup.stream {
                await self.drainActions()
            }
        }
        // the first snapshot never holds the UI up: the database already has something to show
        Task { try? await self.refreshSnapshot() }
        Task { await self.replenishPrekeysIfNeeded() }
        Task { await self.refreshBlocked() }
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sweepExpiredMutes()
                await self?.sweepExpiredMessages()
                // the unreadable queue is replayed at start and then on a loop:
                // an envelope waiting for its key would otherwise wait for the
                // next frame that opens in the same chat, which may never come
                await self?.sweepUnreadable()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private var prekeysChecked = false

    /// Once per session: if fewer than 20 of our one-time prekeys are left on
    /// the server, make up the difference to 100 and upload the new ones.
    private func replenishPrekeysIfNeeded() async {
        guard !prekeysChecked else { return }
        prekeysChecked = true
        do {
            let remaining = try await api.prekeyCount()
            guard remaining < 20 else { return }
            let fresh = try e2ee.moreOneTimePrekeys(count: 100 - remaining)
            try await api.uploadPrekeys(fresh.map {
                .init(id: $0.id, key: $0.key.publicKey.rawRepresentation.base64urlEncodedString())
            })
        } catch {
            prekeysChecked = false // no network, so the next start() checks again
        }
    }

    public func stop() async {
        eventTask?.cancel()
        outboxTask?.cancel()
        actionTask?.cancel()
        maintenanceTask?.cancel()
        expiryTask?.cancel()
        await ws.stop()
        connected = false
    }

    public var isConnected: Bool { connected }

    /// The app went to the background: presence drops to offline at once,
    /// without waiting for the TTL.
    public func appEnteredBackground() async {
        try? await ws.sendRaw(Data(#"{"t":"bg"}"#.utf8))
    }

    /// Back on screen: presence online, plus a nudge to the reconnect and the outbox.
    public func appBecameActive() async {
        // While the app was away the notification service extension wrote
        // messages of its own into this file, and an observation only hears the
        // writes of its own process. Coming back to the screen is the moment
        // the screens are told to look again.
        try? await db.write { dbc in
            try dbc.notifyChanges(in: Table("message"))
            try dbc.notifyChanges(in: Table("chat"))
            try dbc.notifyChanges(in: Table("badge"))
        }
        await ws.nudge()
        try? await ws.sendRaw(Data(#"{"t":"fg"}"#.utf8))
        outboxWakeup.continuation.yield()
        await sweepExpiredMutes()
    }

    /// Messages past their deadline leave the device together with their attachments.
    /// The sweep runs on the maintenance loop and is woken for the nearest deadline
    /// as well: with a short TTL, a half-minute loop would not be enough.
    public func sweepExpiredMessages() async {
        let now = Date().timeIntervalSince1970
        let doomed = (try? await db.read { dbc in
            try Message.fetchAll(dbc, sql: "SELECT * FROM message WHERE expiresAt IS NOT NULL AND expiresAt <= ?",
                                 arguments: [now])
        }) ?? []
        if !doomed.isEmpty {
            try? await db.write { dbc in try ChatCleanup.expire(dbc, now: now) }
            for info in doomed.flatMap({ ($0.media.map { [$0] } ?? []) + ($0.album ?? []) }) {
                media?.remove(info)
            }
        }
        await scheduleNextExpiry()
    }

    /// An alarm for the nearest deadline: without it a message with a five-second
    /// TTL would stay on screen until the next maintenance loop.
    private func scheduleNextExpiry() async {
        expiryTask?.cancel()
        let next = (try? await db.read { dbc in
            try Double.fetchOne(dbc, sql: "SELECT MIN(expiresAt) FROM message WHERE expiresAt IS NOT NULL")
        }) ?? nil
        guard let next else { return }
        let delay = max(0, next - Date().timeIntervalSince1970)
        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000) + 200_000_000)
            guard !Task.isCancelled else { return }
            await self?.sweepExpiredMessages()
        }
    }

    /// Unmutes the chats whose mute has run out, here and on the server.
    /// The server treats an expired mute as lifted on its own, but without
    /// clearing it the flag would come back with the next snapshot.
    public func sweepExpiredMutes() async {
        let now = Date().timeIntervalSince1970
        let expired: [String] = (try? await db.write { dbc in
            let ids = try String.fetchAll(dbc, sql: """
                SELECT id FROM chat WHERE muted = 1 AND mutedUntil IS NOT NULL AND mutedUntil <= ?
                """, arguments: [now])
            if !ids.isEmpty {
                try dbc.execute(sql: """
                    UPDATE chat SET muted = 0, mutedUntil = NULL
                    WHERE muted = 1 AND mutedUntil IS NOT NULL AND mutedUntil <= ?
                    """, arguments: [now])
            }
            return ids
        }) ?? []
        for chatId in expired {
            try? await api.setChatFlags(chatId, muted: false)
        }
    }

    /// Pulls the server's block list into the local user.isBlocked flag.
    public func refreshBlocked() async {
        guard let ids = try? await api.blockedUsers() else { return }
        try? await db.write { dbc in try SyncEngine.applyBlockedList(dbc, serverIds: ids) }
    }

    /// The server list laid over the local flags. A block that has not reached the
    /// server yet is not cancelled by it: otherwise the user's decision would roll
    /// itself back on the very first update.
    static func applyBlockedList(_ dbc: GRDB.Database, serverIds: [String]) throws {
        let queued = try String.fetchAll(
            dbc, sql: "SELECT payload FROM pendingAction WHERE type = 'block'")
            .compactMap { try? JSONDecoder().decode(BlockActionPayload.self, from: Data($0.utf8)) }
        var blocked = Set(serverIds)
        for q in queued {
            if q.blocked { blocked.insert(q.userId) } else { blocked.remove(q.userId) }
        }
        try dbc.execute(sql: "UPDATE user SET isBlocked = 0 WHERE isBlocked = 1")
        for id in blocked {
            try dbc.execute(sql: "UPDATE user SET isBlocked = 1 WHERE id = ?", arguments: [id])
        }
    }

    /// Blocks a peer: the local flag right away (it disables the input bar), the
    /// server through the action queue, so the decision survives being offline.
    public func setBlocked(userId: String, blocked: Bool) async throws {
        let payload = String(data: try JSONEncoder().encode(
            BlockActionPayload(userId: userId, blocked: blocked)), encoding: .utf8)!
        try await db.write { dbc in
            try dbc.execute(sql: "UPDATE user SET isBlocked = ? WHERE id = ?",
                            arguments: [blocked, userId])
            try dbc.execute(
                sql: """
                INSERT INTO pendingAction (id, type, chatId, payload, createdAt) VALUES (?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, attempts = 0
                """,
                arguments: ["block:\(userId)", "block", nil, payload, Date().timeIntervalSince1970])
        }
        actionWakeup.continuation.yield()
    }

    private func handle(_ ev: WSEvent) async {
        switch ev {
        case .connected:
            connected = true
            connectionStream.send(true)
            await sendSyncCursors()
            outboxWakeup.continuation.yield()
            actionWakeup.continuation.yield()
            // the link is back: keys that were missing may have arrived, and a
            // repair request now has somewhere to go
            Task { await self.sweepUnreadable() }
        case .disconnected:
            connected = false
            connectionStream.send(false)
            // the portion broke off: the next connection restarts the catch-up
            // from the cursors confirmed in the database
            catchupPending = []
            catchupSent = [:]
        case .unauthorized:
            connected = false
            connectionStream.send(false)
            sessionRevokedStream.send(())
        case .outdated:
            connected = false
            connectionStream.send(false)
            MsngrLog.session.error(
                "server refused protocol v\(MsngrProtocol.version, privacy: .public): this build is out of date")
            protocolOutdatedStream.send(())
        case .frame(let data):
            guard let frame = try? JSONDecoder().decode(WSIncoming.self, from: data) else { return }
            // frames are queued rather than applied here: the socket hands them
            // over faster than the database takes them one at a time, and a
            // queue is what lets a run of messages share a transaction
            incoming.append(frame)
            if !applyingIncoming {
                Task { await self.drainIncoming() }
            }
        }
    }

    /// Frames received and not applied yet, in arrival order.
    private var incoming: [WSIncoming] = []
    private var applyingIncoming = false

    /// Messages one transaction takes. Long enough that a burst pays for the
    /// feed refresh once per group, short enough that the first message of a
    /// quiet chat still lands immediately — the queue is normally empty and the
    /// group is one frame.
    static let incomingBatchSize = 200

    /// Applies what the socket handed over, grouping the runs of message frames.
    /// Everything else keeps its own turn, so the order frames arrived in is the
    /// order they are applied in.
    private func drainIncoming() async {
        guard !applyingIncoming else { return }
        applyingIncoming = true
        defer { applyingIncoming = false }
        while !incoming.isEmpty {
            if incoming[0].t == "msg" {
                var run: [WSIncoming] = []
                while let next = incoming.first, next.t == "msg", run.count < Self.incomingBatchSize {
                    run.append(incoming.removeFirst())
                }
                await applyIncomingBatch(run)
            } else {
                await apply(incoming.removeFirst())
            }
        }
    }

    // MARK: - Snapshot and sync

    public func refreshSnapshot() async throws {
        let snap = try await api.chatsSnapshot()
        try await applySnapshot(snap)
        await sendSyncCursors()
    }

    private func applySnapshot(_ snap: APIClient.ChatsSnapshot) async throws {
        // a chat deleted here while offline is still on the server's list until
        // the queued request lands
        let deleting = await chatsBeingDeleted()
        try await db.write { [ownUserId] dbc in
            for u in snap.users {
                try SyncEngine.upsertUser(dbc, u)
            }
            for entry in snap.chats where !deleting.contains(entry.state.chatId) {
                try SyncEngine.upsertChatState(
                    dbc, entry.state, ownUserId: ownUserId,
                    flags: ChatFlags(pinned: entry.flags.pinned, muted: entry.flags.muted,
                                     mutedUntil: entry.flags.mutedUntil, archived: entry.flags.archived))
            }
        }
    }

    /// Chats that still had history past their cursor after the last portion.
    private var catchupPending: Set<String> = []
    /// Cursors of the portion last asked for. The next request only goes out
    /// with different ones, otherwise the catch-up would spin in place.
    private var catchupSent: [String: Int] = [:]

    /// Opens the catch-up: every chat the client knows, from its confirmed bounds.
    private func sendSyncCursors() async {
        guard connected else { return }
        let cursors = (try? await db.read { dbc in
            try HistoryWindow.catchupCursors(dbc)
        }) ?? [:]
        catchupPending = []
        catchupSent = cursors
        try? await ws.send(.sync(cursors: cursors))
    }

    /// Catch-up progress for one chat. The cursor is confirmed only once the
    /// portion has been applied (its frames arrive before `syncState`), so a
    /// break in the middle of a catch-up costs one portion, not the history.
    private func applySyncState(_ f: WSIncoming) async {
        guard let chatId = f.chatId, let cursor = f.cursor else { return }
        try? await db.write { dbc in
            try dbc.execute(sql: "UPDATE chat SET syncCursor = MAX(syncCursor, ?) WHERE id = ?",
                            arguments: [cursor, chatId])
        }
        if f.more == true { catchupPending.insert(chatId) } else { catchupPending.remove(chatId) }
    }

    /// End of a portion: while the server says there is more to replay, the
    /// client asks for the next one from the cursors the database confirmed.
    /// Between portions the session object is free for live traffic, which is
    /// why the catch-up runs as a loop of frames rather than one long request.
    private func finishCatchupPortion(more: Bool) async {
        guard more, connected else { return }
        let pending = catchupPending
        let cursors = (try? await db.read { dbc -> [String: Int] in
            let behind = try HistoryWindow.catchupCursors(dbc)
                .filter { pending.contains($0.key) }
            // the portion ran out before it reached the chats that are behind:
            // ask for those whose journal is known to run past their cursor
            return behind.isEmpty ? try HistoryWindow.catchupCursors(dbc, behindOnly: true) : behind
        }) ?? [:]
        guard !cursors.isEmpty, cursors != catchupSent else { return }
        catchupSent = cursors
        try? await ws.send(.catchup(cursors: cursors))
    }

    // MARK: - Applying incoming frames

    func apply(_ f: WSIncoming) async {
        switch f.t {
        case "msg":
            await applyIncomingBatch([f])
        case "sent":
            await applySentAck(f)
        case "receipt":
            await applyReceipt(f)
        case "typing":
            if let chatId = f.chatId, let from = f.from {
                typingStream.send((chatId, from, f.kind))
            }
        case "presence":
            if let userId = f.userId, let online = f.online {
                try? await db.write { dbc in
                    try dbc.execute(sql: "UPDATE user SET online = ?, lastSeen = ? WHERE id = ?",
                                    arguments: [online, f.lastSeen ?? 0, userId])
                }
            }
        case "chat":
            // removed from the chat while the device was offline: such a frame
            // carries no roster, and there is nothing left to catch up on
            if f.event == "removed", let chatId = f.chatId {
                let attachments = await chatMedia(chatId: chatId)
                try? await db.write { dbc in
                    try ChatCleanup.deleteChat(dbc, chatId: chatId)
                }
                for info in attachments { media?.remove(info) }
                return
            }
            if let state = f.state {
                // a direct chat deleted here keeps its membership on the
                // server, so events about it still reach this device: a title
                // or a pin must not put the chat back, only a message does.
                // A membership change is the exception — that is how a group
                // this device left takes it back in.
                if f.event != "members" {
                    let deleted = (try? await db.read { dbc in
                        try Bool.fetchOne(dbc, sql: """
                            SELECT NOT EXISTS(SELECT 1 FROM chat WHERE id = ?)
                              AND EXISTS(SELECT 1 FROM chatTombstone WHERE chatId = ?)
                            """, arguments: [state.chatId, state.chatId]) ?? false
                    }) ?? false
                    if deleted { return }
                }
                // the old roster has to be read before the member table is rewritten
                let previousMembers: [String] = (try? await db.read { dbc in
                    try String.fetchAll(dbc, sql: "SELECT userId FROM member WHERE chatId = ?", arguments: [state.chatId])
                }) ?? []
                try? await db.write { [ownUserId] dbc in
                    try SyncEngine.upsertChatState(dbc, state, ownUserId: ownUserId, flags: nil)
                }
                // removed from the chat: it goes from this device as well
                if !state.members.contains(where: { $0.userId == ownUserId }) {
                    try? await db.write { dbc in
                        try dbc.execute(sql: "DELETE FROM chat WHERE id = ?", arguments: [state.chatId])
                    }
                }
                // someone left the group: our sender key chain rotates so that
                // whoever left cannot read what is sent from now on. The roster is
                // checked against any frame that carries it: the device may have
                // missed the live members event, and then learns about the
                // departure only from the roster replayed while catching up.
                if state.kind == "group" {
                    let current = Set(state.members.map(\.userId))
                    if !Set(previousMembers).subtracting(current).isEmpty {
                        try? e2ee.rotateSenderKey(chatId: state.chatId)
                    }
                }
                // a chat frame carries member ids only, so profiles of new
                // users are fetched; without it the UI shows a placeholder
                // name until the next launch
                await fetchMissingUsers(state.members.map(\.userId))
            }
        case "syncState":
            await applySyncState(f)
        case "syncDone":
            await finishCatchupPortion(more: f.more ?? false)
        case "error":
            await applyServerError(f)
        case "deleted":
            if let chatId = f.chatId, let msgIds = f.msgIds {
                try? await db.write { dbc in
                    for id in msgIds {
                        try dbc.execute(
                            sql: """
                            UPDATE message SET deletedForAll = 1, text = NULL, media = NULL,
                            album = NULL, kind = 'text' WHERE chatId = ? AND msgId = ?
                            """,
                            arguments: [chatId, id])
                        // nothing matched: the original has not been stored
                        // yet, so the tombstone waits for it
                        if dbc.changesCount == 0 {
                            try SyncEngine.bufferPendingApply(dbc, chatId: chatId, targetMsgId: id,
                                                              kind: "deleted", fromUserId: f.by ?? "",
                                                              payload: "{}", seq: nil)
                        }
                    }
                }
            }
        default:
            break
        }
    }

    private var snapshotRefreshInFlight = false
    /// Users whose profile request is already in flight, so a burst of frames
    /// from one unknown sender does not become a burst of identical requests.
    private var userFetchesInFlight: Set<String> = []

    /// Fetches the profiles of users the user table does not hold yet.
    private func fetchMissingUsers(_ ids: [String]) async {
        let missing: [String] = (try? await db.read { dbc in
            try ids.filter { id in
                try !Bool.fetchOne(dbc, sql: "SELECT EXISTS(SELECT 1 FROM user WHERE id = ?)",
                                   arguments: [id])!
            }
        }) ?? []
        for id in missing where !userFetchesInFlight.contains(id) {
            userFetchesInFlight.insert(id)
            // the network stays off the frame-applying path: a message never
            // waits for a profile
            Task { await self.fetchAndStoreUser(id) }
        }
    }

    private func fetchAndStoreUser(_ id: String) async {
        defer { userFetchesInFlight.remove(id) }
        guard let resp = try? await api.user(id) else { return }
        try? await db.write { dbc in
            try SyncEngine.upsertUser(dbc, resp.user)
            if let p = resp.presence {
                try dbc.execute(sql: "UPDATE user SET online = ?, lastSeen = ? WHERE id = ?",
                                arguments: [p.online, p.lastSeen, id])
            }
        }
    }

    /// An incoming message frame with the fields every path below needs.
    private struct IncomingFrame {
        let chatId: String, msgId: String, seq: Int
        let from: String, fromDevice: String
        let sentAt: Double, ts: Double
        let body: JSONValue?
        let isService: Bool
    }

    /// Applies a run of message frames.
    ///
    /// The rows of the run and the cursor moves they cause share one
    /// transaction, and the delivery receipt for the run is one frame. A burst
    /// therefore costs the feed one refresh per run instead of one per message,
    /// which is what the database queue spends its time on.
    ///
    /// Plain content is what a run is made of. Anything else — a key
    /// distribution, a repair, an envelope that did not open — may change what
    /// the frames after it decrypt to, so it ends the run and is applied on its
    /// own before the next one starts.
    private func applyIncomingBatch(_ frames: [WSIncoming]) async {
        var items: [IncomingFrame] = frames.compactMap { f in
            guard let chatId = f.chatId, let msgId = f.msgId, let seq = f.seq,
                  let from = f.from, let fromDevice = f.fromDevice else { return nil }
            return IncomingFrame(chatId: chatId, msgId: msgId, seq: seq, from: from,
                                 fromDevice: fromDevice, sentAt: f.sentAt ?? 0, ts: f.ts ?? 0,
                                 body: f.body, isService: f.service == true)
        }
        guard !items.isEmpty else { return }
        var chatIds = Set(items.map(\.chatId))

        // whoever has just sent a message is no longer typing: the sender's own
        // stop frame can be late or lost, and the indicator would then cover the
        // message that has already arrived. One event per sender per batch: a
        // catch-up of hundreds of messages must not cost hundreds of them
        var stopped = Set<String>()
        for item in items where !item.isService {
            if stopped.insert(item.chatId + "\u{1}" + item.from).inserted {
                typingStream.send((item.chatId, item.from, nil))
            }
        }

        // a message for a chat we do not have means we missed its creation
        func storedChats(_ ids: Set<String>) async -> Set<String> {
            (try? await db.read { dbc in
                try String.fetchSet(dbc, sql: """
                    SELECT id FROM chat WHERE id IN (\(databaseQuestionMarks(count: ids.count)))
                    """, arguments: StatementArguments([String](ids)))
            }) ?? []
        }
        let knownChats = await storedChats(chatIds)
        if !chatIds.subtracting(knownChats).isEmpty, !snapshotRefreshInFlight {
            snapshotRefreshInFlight = true
            try? await refreshSnapshot()
            snapshotRefreshInFlight = false
            // the snapshot leaves out a chat this device is deleting; its
            // frames are dropped rather than written under a chat that has no
            // row, and the catch-up replays them if the chat ever comes back
            let present = await storedChats(chatIds)
            if present.count < chatIds.count {
                items = items.filter { present.contains($0.chatId) }
                guard !items.isEmpty else { return }
                chatIds = Set(items.map(\.chatId))
            }
        }
        // a sender with no profile stored yet, so that the name shows on the
        // message right away
        await fetchMissingUsers([String](Set(items.map(\.from))))

        // own echo from another device, or the ack path: deduplicated by msgId
        let msgIds = items.map(\.msgId)
        let stored = (try? await db.read { dbc in
            try String.fetchSet(dbc, sql: """
                SELECT msgId FROM message WHERE msgId IN (\(databaseQuestionMarks(count: msgIds.count)))
                """, arguments: StatementArguments(msgIds))
        }) ?? []

        var content: [(IncomingFrame, ContentPayload)] = []
        var cursors: [IncomingFrame] = []
        var announce: [IncomingFrame] = []
        /// chats this run put something into: their deferred envelopes get a try
        var touched: Set<String> = []
        var replayed: Set<String> = []

        func flush() async {
            guard !content.isEmpty || !cursors.isEmpty else { return }
            let rows = content, moves = cursors
            content = []
            cursors = []
            try? await db.write { [ownUserId] dbc in
                for (item, payload) in rows {
                    try SyncEngine.applyContent(dbc, payload, chatId: item.chatId, msgId: item.msgId,
                                                seq: item.seq, from: item.from, sentAt: item.sentAt,
                                                ts: item.ts, ownUserId: ownUserId)
                }
                for item in moves {
                    try SyncEngine.advanceChat(dbc, chatId: item.chatId, seq: item.seq,
                                               isOwn: item.from == ownUserId, isService: item.isService)
                }
            }
        }

        for item in items {
            let fresh = !stored.contains(item.msgId)
            if fresh, let body = item.body {
                let result: DecryptedIncoming
                if item.from == ownUserId && item.fromDevice == ownDeviceId {
                    result = .undecryptable(reason: "own_echo") // already stored under its clientMsgId
                } else {
                    result = (try? e2ee.decrypt(envelopeJSON: body, chatId: item.chatId,
                                                fromUserId: item.from, fromDeviceId: item.fromDevice))
                        ?? .undecryptable(reason: "exception")
                }
                switch result {
                case .content(let payload) where !Self.repairKinds.contains(payload.kind):
                    content.append((item, payload))
                    touched.insert(item.chatId)
                case .undecryptable(let reason):
                    await flush()
                    await recordUnreadable(reason: reason, chatId: item.chatId, msgId: item.msgId,
                                           seq: item.seq, from: item.from, fromDevice: item.fromDevice,
                                           sentAt: item.sentAt, ts: item.ts, body: body)
                default:
                    await flush()
                    await storeIncoming(result, chatId: item.chatId, msgId: item.msgId, seq: item.seq,
                                        from: item.from, fromDevice: item.fromDevice,
                                        sentAt: item.sentAt, ts: item.ts)
                    await retryPending(chatId: item.chatId)
                    replayed.insert(item.chatId)
                }
            }
            cursors.append(item)
            if fresh, item.body != nil { announce.append(item) }
        }
        await flush()
        for chatId in touched where !replayed.contains(chatId) {
            await retryPending(chatId: chatId)
        }

        // one recv ack per chat for the whole run (the author's delivered ticks);
        // an unaccepted request sends none, the recipient is invisible to the author.
        // The receipt is written down before it is sent: a socket that dies
        // between the message and its answer would otherwise leave the author on
        // one tick until something else arrives in the chat
        var queued = false
        for chatId in chatIds {
            let top = items.filter { $0.chatId == chatId && $0.from != ownUserId }.map(\.seq).max()
            guard let top else { continue }
            let isRequestChat = (try? await db.read { dbc in
                try Bool.fetchOne(dbc, sql: "SELECT isRequest FROM chat WHERE id = ?",
                                  arguments: [chatId]) ?? false
            }) ?? false
            guard !isRequestChat else { continue }
            try? await db.write { dbc in
                try DeliveryReceipts.record(dbc, chatId: chatId, upToSeq: top)
            }
            queued = true
        }
        if queued { actionWakeup.continuation.yield() }
        // the in-app banner is told last, when the row it previews is written
        for item in announce {
            incomingMessageStream.send(IncomingMessage(
                chatId: item.chatId, msgId: item.msgId, fromUserId: item.from,
                isService: item.isService, isOwn: item.from == ownUserId))
        }
    }

    /// Moves a chat's cursors for one applied frame.
    static func advanceChat(_ dbc: GRDB.Database, chatId: String, seq: Int,
                            isOwn: Bool, isService: Bool) throws {
        if isService {
            // in a chat that is fully read, myReadUpTo swallows the seq, so the
            // derived unread of later messages does not count a service frame
            try dbc.execute(
                sql: """
                UPDATE chat SET
                  lastSeq = MAX(lastSeq, ?),
                  syncedSeq = CASE WHEN ? = syncedSeq + 1 THEN ? ELSE syncedSeq END,
                  myReadUpTo = CASE WHEN ? OR myReadUpTo >= ? - 1 THEN MAX(myReadUpTo, ?) ELSE myReadUpTo END
                WHERE id = ?
                """,
                arguments: [seq, seq, seq, isOwn, seq, seq, chatId])
        } else {
            try dbc.execute(
                sql: """
                UPDATE chat SET
                  lastSeq = MAX(lastSeq, ?),
                  syncedSeq = CASE WHEN ? = syncedSeq + 1 THEN ? ELSE syncedSeq END,
                  myReadUpTo = CASE WHEN ? THEN MAX(myReadUpTo, ?) ELSE myReadUpTo END,
                  unreadCount = MAX(0, MAX(lastSeq, ?) - CASE WHEN ? THEN MAX(myReadUpTo, ?) ELSE myReadUpTo END)
                WHERE id = ?
                """,
                arguments: [seq, seq, seq, isOwn, seq, seq, isOwn, seq, chatId])
        }
    }

    // MARK: - Unreadable messages

    /// An envelope this device could not open, with the counters of what has
    /// been tried on it.
    private struct PendingEnvelope {
        let chatId: String, msgId: String, seq: Int
        let from: String, fromDevice: String
        let sentAt: Double, ts: Double
        let body: Data
        let reason: String?
        let attempts: Int
        let firstSeenAt: Double, lastTriedAt: Double
        let repairAttempts: Int, repairAskedAt: Double
    }

    /// Keeps an envelope that did not open, and records the seq it left unfilled.
    ///
    /// The envelope is kept whatever the reason: this database is its only copy,
    /// and once the session is repaired there would otherwise be nothing left to
    /// retry. Recording the seq takes the failure out of silence: pagination
    /// stops asking the server for that range, and the feed knows the message is
    /// lost rather than absent.
    private func recordUnreadable(reason rawReason: String, chatId: String, msgId: String, seq: Int,
                                  from: String, fromDevice: String, sentAt: Double,
                                  ts: Double, body: JSONValue) async {
        guard rawReason != "own_echo" else { return }
        // The extension may have opened this very envelope from its push and
        // written the message already; its ratchet step is exactly why this
        // attempt failed. Nothing is missing, so nothing is recorded.
        guard await !stored(msgId: msgId) else { return }
        let reason: String
        if rawReason == "not_addressed" {
            // in a direct chat the sender addresses every device on both sides,
            // so a box missing for us is a defect and gets repaired; in a group
            // an addressed frame (key distribution, repair) goes to one member
            // by design
            let kind = (try? await db.read { dbc in
                try String.fetchOne(dbc, sql: "SELECT kind FROM chat WHERE id = ?", arguments: [chatId])
            }) ?? nil
            guard kind == ChatKind.direct.rawValue else {
                try? await db.write { dbc in
                    try HistoryWindow.recordGap(dbc, chatId: chatId, seq: seq, reason: rawReason,
                                                msgId: msgId, fromUserId: from, sentAt: sentAt)
                }
                return
            }
            reason = "no_ciphertext"
        } else {
            reason = rawReason
        }
        guard let data = try? JSONEncoder().encode(body) else { return }
        let now = Date().timeIntervalSince1970
        let attempts = (try? await db.write { dbc -> Int in
            try SyncEngine.deferEnvelope(dbc, reason: reason, chatId: chatId, msgId: msgId, seq: seq,
                                         from: from, fromDevice: fromDevice, sentAt: sentAt, ts: ts,
                                         body: data, now: now)
        }) ?? 1
        MsngrLog.repair.error(
            "unreadable chat=\(chatId, privacy: .public) seq=\(seq, privacy: .public) reason=\(reason, privacy: .public) attempts=\(attempts, privacy: .public)")
        // a reason that will not clear on its own: ask the sender for a copy now
        guard !MessageRepair.retryableReasons.contains(reason) else { return }
        let pending = PendingEnvelope(chatId: chatId, msgId: msgId, seq: seq, from: from,
                                      fromDevice: fromDevice, sentAt: sentAt, ts: ts, body: data,
                                      reason: reason, attempts: attempts, firstSeenAt: now,
                                      lastTriedAt: now, repairAttempts: 0, repairAskedAt: 0)
        await requestRepairIfDue(pending, now: now)
    }

    /// Whether the feed already holds this message, whoever wrote it.
    private func stored(msgId: String) async -> Bool {
        (try? await db.read { dbc in
            try Bool.fetchOne(dbc, sql: "SELECT EXISTS(SELECT 1 FROM message WHERE msgId = ?)",
                              arguments: [msgId]) ?? false
        }) ?? false
    }

    /// Keeps an envelope this device could not open, and marks the seq it left
    /// unfilled. Returns how many times this envelope has been tried.
    ///
    /// The notification service extension writes here too: an envelope that
    /// arrived by push and did not open is the only copy the device has until
    /// the socket replays it, and the sweep in the app works from this table.
    @discardableResult
    static func deferEnvelope(_ dbc: GRDB.Database, reason: String, chatId: String, msgId: String,
                              seq: Int, from: String, fromDevice: String, sentAt: Double,
                              ts: Double, body: Data, now: Double) throws -> Int {
        try dbc.execute(
            sql: """
            INSERT INTO pendingDecrypt (chatId, msgId, seq, fromUserId, fromDevice, sentAt, ts,
                                        body, reason, attempts, firstSeenAt, lastTriedAt)
            VALUES (?,?,?,?,?,?,?,?,?,1,?,?)
            ON CONFLICT(chatId, msgId) DO UPDATE SET
              reason = excluded.reason, attempts = pendingDecrypt.attempts + 1,
              lastTriedAt = excluded.lastTriedAt
            """,
            arguments: [chatId, msgId, seq, from, fromDevice, sentAt, ts, body, reason, now, now])
        try HistoryWindow.recordGap(dbc, chatId: chatId, seq: seq, reason: reason,
                                    msgId: msgId, fromUserId: from, sentAt: sentAt, now: now)
        return try Int.fetchOne(dbc, sql: "SELECT attempts FROM pendingDecrypt WHERE chatId = ? AND msgId = ?",
                                arguments: [chatId, msgId]) ?? 1
    }

    private func pendingEnvelopes(chatId: String?) async -> [PendingEnvelope] {
        let sql = chatId == nil
            ? "SELECT * FROM pendingDecrypt ORDER BY chatId, seq"
            : "SELECT * FROM pendingDecrypt WHERE chatId = ? ORDER BY seq"
        let arguments: StatementArguments = chatId.map { [$0] } ?? []
        return (try? await db.read { dbc in
            try Row.fetchAll(dbc, sql: sql, arguments: arguments).map {
                PendingEnvelope(chatId: $0["chatId"], msgId: $0["msgId"], seq: $0["seq"],
                                from: $0["fromUserId"], fromDevice: $0["fromDevice"],
                                sentAt: $0["sentAt"], ts: $0["ts"], body: $0["body"],
                                reason: $0["reason"], attempts: $0["attempts"],
                                firstSeenAt: $0["firstSeenAt"], lastTriedAt: $0["lastTriedAt"],
                                repairAttempts: $0["repairAttempts"], repairAskedAt: $0["repairAskedAt"])
            }
        }) ?? []
    }

    /// Replays a chat's deferred envelopes at once: the key that has just
    /// arrived opens everything that was waiting for it, so there is nothing to
    /// wait for here. One of those envelopes may itself be a key distribution
    /// that unlocks more, so the pass repeats while it keeps making progress.
    private func retryPending(chatId: String) async {
        for _ in 0..<4 {
            var progress = false
            for pending in await pendingEnvelopes(chatId: chatId) {
                if await replay(pending) { progress = true }
            }
            if !progress { return }
        }
    }

    private var sweeping = false

    /// A pass over every deferred envelope: replay what may open now, ask the
    /// sender for what will not, drop what is out of chances. Runs at engine
    /// start, on every reconnect, and on a background loop.
    public func sweepUnreadable() async {
        guard !sweeping else { return }
        sweeping = true
        defer { sweeping = false }
        let now = Date().timeIntervalSince1970
        for pending in await pendingEnvelopes(chatId: nil) {
            if MessageRepair.expired(firstSeenAt: pending.firstSeenAt,
                                     repairAttempts: pending.repairAttempts, now: now) {
                await dropExpired(pending)
                continue
            }
            if MessageRepair.retryDue(lastTriedAt: pending.lastTriedAt, now: now),
               await replay(pending) {
                continue
            }
            await requestRepairIfDue(pending, now: now)
        }
    }

    /// One attempt at a stored envelope. Success moves it into the feed and
    /// closes the record of the gap; failure counts as an attempt.
    private func replay(_ pending: PendingEnvelope) async -> Bool {
        // The message may already be in the feed: the notification service
        // extension opens the same envelope from the push, and the ratchet moved
        // with it. Trying again would fail for good and set repair going after a
        // message that is not missing at all.
        if await stored(msgId: pending.msgId) {
            try? await db.write { dbc in
                try dbc.execute(sql: "DELETE FROM pendingDecrypt WHERE chatId = ? AND msgId = ?",
                                arguments: [pending.chatId, pending.msgId])
                try dbc.execute(sql: "DELETE FROM historyGap WHERE chatId = ? AND seq = ?",
                                arguments: [pending.chatId, pending.seq])
            }
            return true
        }
        guard let body = try? JSONDecoder().decode(JSONValue.self, from: pending.body) else {
            await dropExpired(pending)
            return false
        }
        let result = (try? e2ee.decrypt(envelopeJSON: body, chatId: pending.chatId,
                                        fromUserId: pending.from, fromDeviceId: pending.fromDevice))
            ?? .undecryptable(reason: "exception")
        if case .undecryptable(let reason) = result {
            try? await db.write { dbc in
                try dbc.execute(
                    sql: """
                    UPDATE pendingDecrypt SET attempts = attempts + 1, reason = ?, lastTriedAt = ?
                    WHERE chatId = ? AND msgId = ?
                    """,
                    arguments: [reason, Date().timeIntervalSince1970, pending.chatId, pending.msgId])
            }
            return false
        }
        await storeIncoming(result, chatId: pending.chatId, msgId: pending.msgId, seq: pending.seq,
                            from: pending.from, fromDevice: pending.fromDevice,
                            sentAt: pending.sentAt, ts: pending.ts)
        // the seq is settled: by a feed row, and then the gap record goes, or
        // by a silent reason, so pagination does not go after it again
        let settled = Self.settledReason(result)
        try? await db.write { dbc in
            try dbc.execute(sql: "DELETE FROM pendingDecrypt WHERE chatId = ? AND msgId = ?",
                            arguments: [pending.chatId, pending.msgId])
            if let settled {
                try HistoryWindow.recordGap(dbc, chatId: pending.chatId, seq: pending.seq, reason: settled)
            } else {
                try dbc.execute(sql: "DELETE FROM historyGap WHERE chatId = ? AND seq = ?",
                                arguments: [pending.chatId, pending.seq])
            }
        }
        MsngrLog.repair.notice(
            "recovered chat=\(pending.chatId, privacy: .public) seq=\(pending.seq, privacy: .public) after=\(pending.attempts, privacy: .public)")
        return true
    }

    /// The silent reason for a seq that is processed but gets no feed row of its
    /// own. nil means the row is there and the gap record can go.
    private static func settledReason(_ result: DecryptedIncoming) -> String? {
        switch result {
        case .senderKeyDistribution: return "sender_key"
        case .identityChanged(_, .none): return "identity_changed"
        case .content(let content), .identityChanged(_, .some(let content)):
            return serviceKinds.contains(content.kind) ? "service" : nil
        case .undecryptable(let reason): return reason
        }
    }

    /// The envelope is out of chances: the session it was encrypted to is long
    /// gone and the repair attempts are spent. The record of the seq stays.
    private func dropExpired(_ pending: PendingEnvelope) async {
        try? await db.write { dbc in
            try dbc.execute(sql: "DELETE FROM pendingDecrypt WHERE chatId = ? AND msgId = ?",
                            arguments: [pending.chatId, pending.msgId])
            try HistoryWindow.recordGap(dbc, chatId: pending.chatId, seq: pending.seq,
                                        reason: pending.reason ?? "unknown",
                                        msgId: pending.msgId, fromUserId: pending.from,
                                        sentAt: pending.sentAt)
        }
        MsngrLog.repair.error(
            "gave up chat=\(pending.chatId, privacy: .public) seq=\(pending.seq, privacy: .public) reason=\(pending.reason ?? "unknown", privacy: .public) attempts=\(pending.attempts, privacy: .public)")
    }

    /// Asks the sender for a fresh copy once the attempt count and the backoff
    /// allow it. The user is not part of this: the request goes on its own.
    private func requestRepairIfDue(_ pending: PendingEnvelope, now: Double) async {
        guard MessageRepair.repairDue(reason: pending.reason, firstSeenAt: pending.firstSeenAt,
                                      repairAttempts: pending.repairAttempts,
                                      repairAskedAt: pending.repairAskedAt, now: now) else { return }
        // an unaccepted request: the author must not learn anyone is on the
        // other side, so the envelope waits and a later pass asks for the copy
        let isRequest = (try? await db.read { dbc in
            try Bool.fetchOne(dbc, sql: "SELECT isRequest FROM chat WHERE id = ?",
                              arguments: [pending.chatId]) ?? false
        }) ?? false
        guard !isRequest else { return }
        let attempt = pending.repairAttempts + 1
        // the session failed to open his envelope and the request would leave
        // through that same session; marking it for rebuild sends the request
        // over a fresh X3DH, and the answer comes back into the new one
        if let reason = pending.reason, MessageRepair.sessionReasons.contains(reason) {
            try? e2ee.resetPairwiseSession(with: pending.from)
        }
        var request = ContentPayload(kind: "repairRequest")
        request.to = pending.from
        request.targetMsgId = pending.msgId
        request.repairSeq = pending.seq
        request.reason = pending.reason
        request.attempt = attempt
        try? await enqueue(content: request, chatId: pending.chatId,
                           clientMsgId: MessageRepair.requestId(msgId: pending.msgId, attempt: attempt))
        try? await db.write { dbc in
            try dbc.execute(
                sql: """
                UPDATE pendingDecrypt SET repairAttempts = ?, repairAskedAt = ?
                WHERE chatId = ? AND msgId = ?
                """,
                arguments: [attempt, now, pending.chatId, pending.msgId])
            // the attempt counts for the feed too: the neutral placeholder
            // appears only once a repair has been tried
            try HistoryWindow.recordGap(dbc, chatId: pending.chatId, seq: pending.seq,
                                        reason: pending.reason ?? "unknown",
                                        msgId: pending.msgId, fromUserId: pending.from,
                                        sentAt: pending.sentAt, now: now)
        }
        MsngrLog.repair.notice(
            "repair asked chat=\(pending.chatId, privacy: .public) seq=\(pending.seq, privacy: .public) reason=\(pending.reason ?? "unknown", privacy: .public) attempt=\(attempt, privacy: .public)")
    }

    // MARK: - Repair through the sender

    /// Content kinds of the repair protocol: the addressed request for a copy,
    /// the copy itself, and the acknowledgement of a sender key distribution.
    /// None of them takes a row in the feed.
    static let repairKinds: Set<String> = ["repairRequest", "repair", "skdAck"]

    /// Handles repair protocol content; false means this is ordinary content.
    @discardableResult
    func handleRepairContent(_ content: ContentPayload, chatId: String,
                             from: String, fromDevice: String) async -> Bool {
        switch content.kind {
        case "repairRequest":
            await answerRepairRequest(content, chatId: chatId, from: from)
        case "repair":
            await applyRepair(content, chatId: chatId, from: from)
        case "skdAck":
            if let keyId = content.keyId {
                try? e2ee.confirmSenderKey(chatId: chatId, keyId: keyId,
                                           userId: from, deviceId: fromDevice)
            }
        default:
            return false
        }
        return true
    }

    /// The peer could not read our message, so it is encrypted again with the
    /// current session and sent to him. The copy carries the original msgId, so
    /// in his feed it lands where the missing message was, not beside it.
    private func answerRepairRequest(_ request: ContentPayload, chatId: String, from: String) async {
        guard let target = request.targetMsgId, from != ownUserId else { return }
        // group: the chain never reached him, so the distribution is forgotten
        // and the next message to the chat hands it out again
        if request.reason == "no_sender_key" {
            try? e2ee.forgetSenderKeyDistribution(chatId: chatId, userId: from)
        }
        let row = (try? await db.read { dbc in
            try Message.fetchOne(
                dbc, sql: "SELECT * FROM message WHERE chatId = ? AND msgId = ? AND isOutgoing = 1",
                arguments: [chatId, target])
        }) ?? nil
        guard let row, !row.deletedForAll else {
            MsngrLog.repair.notice(
                "repair asked for a message we do not hold chat=\(chatId, privacy: .public) msgId=\(target, privacy: .public)")
            return
        }
        // a copy is only given for what was addressed to the asker in the first
        // place: otherwise a member who joined later would be handed history
        // that the chain rotation closed to him
        let joinedAt = (try? await db.read { dbc in
            try Double.fetchOne(dbc, sql: "SELECT joinedAt FROM member WHERE chatId = ? AND userId = ?",
                                arguments: [chatId, from])
        }) ?? nil
        guard let joinedAt, row.sentAt >= joinedAt else {
            MsngrLog.repair.notice(
                "repair asked for a message sent before the asker joined chat=\(chatId, privacy: .public) msgId=\(target, privacy: .public)")
            return
        }
        var original = ContentPayload(kind: row.kind.rawValue)
        original.text = row.text
        original.media = row.media
        original.album = row.album
        original.replyTo = row.replyTo
        original.fwd = row.forward
        var reply = ContentPayload(kind: "repair")
        reply.to = from
        reply.repairOf = target
        reply.repairSeq = row.seq ?? request.repairSeq
        reply.origSentAt = row.sentAt
        reply.attempt = request.attempt
        reply.orig = SyncEngine.payloadJSON(original)
        try? await enqueue(content: reply, chatId: chatId,
                           clientMsgId: MessageRepair.replyId(msgId: target,
                                                              attempt: request.attempt ?? 1))
        MsngrLog.repair.notice(
            "repair sent chat=\(chatId, privacy: .public) msgId=\(target, privacy: .public) attempt=\(request.attempt ?? 1, privacy: .public)")
    }

    /// A copy from the sender. It goes in under the original msgId and seq, so
    /// no duplicate appears in the feed, and it closes the record of the gap.
    private func applyRepair(_ repair: ContentPayload, chatId: String, from: String) async {
        guard let target = repair.repairOf, let json = repair.orig,
              let original = try? JSONDecoder().decode(ContentPayload.self, from: Data(json.utf8)),
              let seq = repair.repairSeq, seq > 0 else { return }
        // a copy is accepted only from the author of the missing message, and
        // only where a record of that gap exists: otherwise any member of the
        // chat could write his own text under someone else's msgId
        let author = (try? await db.read { dbc in
            try String.fetchOne(
                dbc, sql: "SELECT fromUserId FROM pendingDecrypt WHERE chatId = ? AND msgId = ?",
                arguments: [chatId, target])
                ?? String.fetchOne(
                    dbc, sql: "SELECT fromUserId FROM historyGap WHERE chatId = ? AND seq = ? AND msgId = ?",
                    arguments: [chatId, seq, target])
        }) ?? nil
        guard author == from else {
            MsngrLog.repair.error(
                "repair rejected chat=\(chatId, privacy: .public) seq=\(seq, privacy: .public): not from the author of the missing message")
            return
        }
        let sentAt = repair.origSentAt ?? 0
        await storeHistoric(content: original, chatId: chatId, msgId: target, seq: seq,
                            from: from, sentAt: sentAt, ts: sentAt)
        try? await db.write { dbc in
            try dbc.execute(sql: "DELETE FROM pendingDecrypt WHERE chatId = ? AND msgId = ?",
                            arguments: [chatId, target])
            if Self.serviceKinds.contains(original.kind) {
                try HistoryWindow.recordGap(dbc, chatId: chatId, seq: seq, reason: "service")
            } else {
                try dbc.execute(sql: "DELETE FROM historyGap WHERE chatId = ? AND seq = ?",
                                arguments: [chatId, seq])
            }
        }
        MsngrLog.repair.notice(
            "repaired chat=\(chatId, privacy: .public) seq=\(seq, privacy: .public)")
    }

    /// Acknowledges a sender key distribution back to whoever sent it: without
    /// this he never learns the chain arrived and keeps handing it out.
    private func confirmSenderKeyDistribution(chatId: String, keyId: String, to userId: String) async {
        var ack = ContentPayload(kind: "skdAck")
        ack.to = userId
        ack.keyId = keyId
        // the ack round matches the distribution round, so a repeated
        // distribution gets a new ack instead of being swallowed by the dedup
        let round = Int(Date().timeIntervalSince1970 / MessageRepair.redistributeAfter)
        try? await enqueue(content: ack, chatId: chatId,
                           clientMsgId: "ska:\(chatId):\(keyId):\(ownDeviceId):\(round)")
    }

    private func storeIncoming(_ result: DecryptedIncoming, chatId: String, msgId: String,
                               seq: Int, from: String, fromDevice: String,
                               sentAt: Double, ts: Double) async {
        switch result {
        case .senderKeyDistribution(let keyChatId, let keyId):
            await confirmSenderKeyDistribution(chatId: keyChatId, keyId: keyId, to: from)
        case .content(let content), .identityChanged(_, .some(let content)):
            if await handleRepairContent(content, chatId: chatId, from: from, fromDevice: fromDevice) {
                if case .identityChanged(let uid, _) = result {
                    await insertSystemMessage(chatId: chatId, text: "identity_changed:\(uid)")
                }
                return
            }
            await applyContent(content, chatId: chatId, msgId: msgId, seq: seq,
                               from: from, sentAt: sentAt, ts: ts)
            if case .identityChanged(let uid, _) = result {
                await insertSystemMessage(chatId: chatId, text: "identity_changed:\(uid)")
            }
        case .identityChanged(let uid, .none):
            await insertSystemMessage(chatId: chatId, text: "identity_changed:\(uid)")
        case .undecryptable(let reason):
            MsngrLog.repair.error(
                "undecryptable reached storage chat=\(chatId, privacy: .public) seq=\(seq, privacy: .public) reason=\(reason, privacy: .public)")
        }
    }

    func applyContent(_ content: ContentPayload, chatId: String, msgId: String,
                      seq: Int, from: String, sentAt: Double, ts: Double) async {
        try? await db.write { [ownUserId] dbc in
            try SyncEngine.applyContent(dbc, content, chatId: chatId, msgId: msgId, seq: seq,
                                        from: from, sentAt: sentAt, ts: ts, ownUserId: ownUserId)
        }
    }

    static func applyContent(_ dbc: GRDB.Database, _ content: ContentPayload, chatId: String,
                             msgId: String, seq: Int, from: String, sentAt: Double, ts: Double,
                             ownUserId: String) throws {
        switch content.kind {
        case "edit":
            if let target = content.targetMsgId {
                try dbc.execute(
                    sql: "UPDATE message SET text = ?, edited = 1 WHERE chatId = ? AND (msgId = ? OR id = ?)",
                    arguments: [content.text, chatId, target, target])
                // nothing matched: the original is not stored yet
                if dbc.changesCount == 0 {
                    try SyncEngine.bufferPendingApply(dbc, chatId: chatId, targetMsgId: target,
                                                      kind: "edit", fromUserId: from,
                                                      payload: SyncEngine.payloadJSON(content), seq: seq)
                }
            }
        case "reaction":
            if let target = content.targetMsgId {
                let found = try SyncEngine.applyReaction(dbc, chatId: chatId, targetMsgId: target,
                                                         userId: from, emoji: content.emoji)
                if !found {
                    try SyncEngine.bufferPendingApply(dbc, chatId: chatId, targetMsgId: target,
                                                      kind: "reaction", fromUserId: from,
                                                      payload: SyncEngine.payloadJSON(content), seq: seq)
                }
            }
        case "disappearing":
            try dbc.execute(sql: "UPDATE chat SET ttlSeconds = ? WHERE id = ?",
                            arguments: [content.ttlSeconds ?? 0, chatId])
        default:
            var msg = Message(id: msgId, chatId: chatId, fromUserId: from, sentAt: sentAt,
                              kind: MessageKind(rawValue: content.kind) ?? .text,
                              text: content.text, status: .sent, isOutgoing: from == ownUserId)
            msg.msgId = msgId
            msg.seq = seq
            msg.serverTs = ts
            msg.media = content.media
            msg.album = content.album
            msg.replyTo = content.replyTo
            msg.forward = content.fwd
            let ttl = try Int.fetchOne(dbc, sql: "SELECT ttlSeconds FROM chat WHERE id = ?", arguments: [chatId]) ?? 0
            if ttl > 0 { msg.expiresAt = Date().timeIntervalSince1970 + Double(ttl) }
            try msg.save(dbc)
            try SyncEngine.applyBuffered(dbc, chatId: chatId, msgId: msgId)
            try dbc.execute(sql: "UPDATE chat SET lastActivityAt = ? WHERE id = ?",
                            arguments: [max(ts, sentAt), chatId])
        }
    }

    /// Applies a message from server history (upward pagination).
    ///
    /// Ordinary content is upserted as a feed row; an edit or a reaction goes
    /// onto its original, or waits for it when the replay order puts the event
    /// before its target. lastActivityAt is left alone: history is older than
    /// whatever the chat is doing now.
    public func storeHistoric(content: ContentPayload, chatId: String, msgId: String,
                              seq: Int, from: String, sentAt: Double, ts: Double) async {
        try? await db.write { [ownUserId] dbc in
            switch content.kind {
            case "edit":
                if let target = content.targetMsgId {
                    try dbc.execute(
                        sql: "UPDATE message SET text = ?, edited = 1 WHERE chatId = ? AND (msgId = ? OR id = ?)",
                        arguments: [content.text, chatId, target, target])
                    if dbc.changesCount == 0 {
                        try SyncEngine.bufferPendingApply(dbc, chatId: chatId, targetMsgId: target,
                                                          kind: "edit", fromUserId: from,
                                                          payload: SyncEngine.payloadJSON(content), seq: seq)
                    }
                }
            case "reaction":
                if let target = content.targetMsgId {
                    let found = try SyncEngine.applyReaction(dbc, chatId: chatId, targetMsgId: target,
                                                             userId: from, emoji: content.emoji)
                    if !found {
                        try SyncEngine.bufferPendingApply(dbc, chatId: chatId, targetMsgId: target,
                                                          kind: "reaction", fromUserId: from,
                                                          payload: SyncEngine.payloadJSON(content), seq: seq)
                    }
                }
            case "disappearing":
                break // the chat's current TTL is in its state; a historic change is not replayed
            default:
                var msg = Message(id: msgId, chatId: chatId, fromUserId: from, sentAt: sentAt,
                                  kind: MessageKind(rawValue: content.kind) ?? .text,
                                  text: content.text, status: .sent, isOutgoing: from == ownUserId)
                msg.msgId = msgId
                msg.seq = seq
                msg.serverTs = ts
                msg.media = content.media
                msg.album = content.album
                msg.replyTo = content.replyTo
                msg.forward = content.fwd
                // a historic copy of a disappearing message is stamped the same way
                // as one that arrived live: otherwise paging up would bring back
                // what has already expired, and it would stay forever
                let ttl = try Int.fetchOne(dbc, sql: "SELECT ttlSeconds FROM chat WHERE id = ?",
                                           arguments: [chatId]) ?? 0
                if ttl > 0 { msg.expiresAt = Date().timeIntervalSince1970 + Double(ttl) }
                try msg.upsert(dbc)
                try SyncEngine.applyBuffered(dbc, chatId: chatId, msgId: msgId)
            }
        }
    }

    /// Closes one seq range this device has never processed.
    ///
    /// Envelopes that decrypt go into the feed through the historic path; every
    /// other seq of the range is written to `historyGap` with the reason it
    /// produced nothing. That keeps the failure out of silence — repair has the
    /// reason and the attempt count to ask the sender again — and stops upward
    /// pagination from requesting the same range on every scroll.
    ///
    /// Returns false when the server did not answer: the range stays open.
    @discardableResult
    public func fillHistoryGap(chatId: String, from: Int, to: Int) async -> Bool {
        guard from <= to else { return true }
        // one request covers at most one server page — a longer range comes
        // back truncated and the tail would be closed without being asked for
        let upper = min(to, from + HistoryWindow.serverPageSize - 1)
        guard let dtos = try? await api.history(chatId: chatId, fromSeq: from - 1,
                                                toSeq: upper, limit: upper - from + 1) else { return false }
        var reasons: [Int: String] = [:]   // seq -> why it produced no feed row
        for m in dtos where m.seq >= from && m.seq <= upper {
            guard m.deleted != true, let body = m.body else {
                reasons[m.seq] = "deleted"
                continue
            }
            guard m.from != ownUserId || m.fromDevice != ownDeviceId else {
                reasons[m.seq] = "own_echo"   // own content already stored under its clientMsgId
                continue
            }
            let result = (try? e2ee.decrypt(envelopeJSON: body, chatId: chatId,
                                            fromUserId: m.from, fromDeviceId: m.fromDevice))
                ?? .undecryptable(reason: "exception")
            switch result {
            case .senderKeyDistribution(let keyChatId, let keyId):
                await confirmSenderKeyDistribution(chatId: keyChatId, keyId: keyId, to: m.from)
                reasons[m.seq] = "sender_key"
            case .content(let content), .identityChanged(_, .some(let content)):
                if await handleRepairContent(content, chatId: chatId, from: m.from,
                                             fromDevice: m.fromDevice) {
                    reasons[m.seq] = "service"
                    break
                }
                await storeHistoric(content: content, chatId: chatId, msgId: m.msgId, seq: m.seq,
                                    from: m.from, sentAt: m.sentAt, ts: m.ts)
                // edit/reaction/disappearing land on their target instead of
                // taking a row of their own — the seq is processed all the same
                if Self.serviceKinds.contains(content.kind) { reasons[m.seq] = "service" }
            case .identityChanged(_, .none):
                reasons[m.seq] = "identity_changed"
            case .undecryptable(let reason):
                // the envelope is kept whatever the reason: it is the only local
                // copy, and repair works from the record it leaves behind
                await recordUnreadable(reason: reason, chatId: chatId, msgId: m.msgId, seq: m.seq,
                                       from: m.from, fromDevice: m.fromDevice,
                                       sentAt: m.sentAt, ts: m.ts, body: body)
            }
            if let reason = reasons[m.seq] {
                try? await db.write { dbc in
                    try HistoryWindow.recordGap(dbc, chatId: chatId, seq: m.seq, reason: reason,
                                                msgId: m.msgId, fromUserId: m.from, sentAt: m.sentAt)
                }
            }
        }
        // seqs the server did not return at all: frames addressed elsewhere or
        // entries it no longer keeps
        let answered = Set(dtos.map(\.seq))
        try? await db.write { dbc in
            for seq in from...upper where !answered.contains(seq) {
                try HistoryWindow.recordGap(dbc, chatId: chatId, seq: seq, reason: "not_addressed")
            }
        }
        return true
    }

    private func insertSystemMessage(chatId: String, text: String) async {
        var msg = Message(id: UUID().uuidString, chatId: chatId, fromUserId: "system",
                          sentAt: Date().timeIntervalSince1970, kind: .system,
                          text: text, status: .sent, isOutgoing: false)
        msg.serverTs = Date().timeIntervalSince1970
        try? await db.write { [msg] dbc in try msg.save(dbc) }
    }

    private func applySentAck(_ f: WSIncoming) async {
        guard let clientMsgId = f.clientMsgId, let msgId = f.msgId,
              let seq = f.seq, let chatId = f.chatId else { return }
        try? await db.write { dbc in
            // a disappearing message's clock runs from the moment it went out:
            // one sitting in the queue without a network has been shown to no one
            let ttl = try Int.fetchOne(dbc, sql: "SELECT ttlSeconds FROM chat WHERE id = ?",
                                       arguments: [chatId]) ?? 0
            try dbc.execute(
                sql: """
                UPDATE message SET msgId = ?, seq = ?, serverTs = ?, status = MAX(status, 1),
                  failReason = NULL, expiresAt = ?
                WHERE clientMsgId = ?
                """,
                arguments: [msgId, seq, f.ts,
                            ttl > 0 ? Date().timeIntervalSince1970 + Double(ttl) : nil,
                            clientMsgId])
            try dbc.execute(sql: "DELETE FROM outbox WHERE clientMsgId = ?", arguments: [clientMsgId])
            // edits and reactions that waited for their target's server id: it is here now
            try dbc.execute(sql: "UPDATE outbox SET state = 'ready' WHERE state = 'waiting'")
            // what we sent counts as read by us, so the badge does not pile up
            try dbc.execute(
                sql: """
                UPDATE chat SET
                  syncedSeq = CASE WHEN ? = syncedSeq + 1 THEN ? ELSE syncedSeq END,
                  lastSeq = MAX(lastSeq, ?), myReadUpTo = MAX(myReadUpTo, ?),
                  lastActivityAt = ? WHERE id = ?
                """,
                arguments: [seq, seq, seq, seq, f.ts ?? Date().timeIntervalSince1970, chatId])
        }
        outboxWakeup.continuation.yield()
    }

    /// The server refused one of our frames. The send stops with the reason
    /// code: repeating what the server rejected changes nothing and would leave
    /// the message sending forever. The queue entry stays as `failed`, so the
    /// message the user sends again is the one they wrote, media and all.
    private func applyServerError(_ f: WSIncoming) async {
        guard let clientMsgId = f.clientMsgId else { return }
        let reason = f.error ?? SendFailure.sendFailed
        try? await db.write { dbc in
            try SyncEngine.markSendFailed(dbc, clientMsgId: clientMsgId, reason: reason)
        }
    }

    /// The send is out of tries. Both marks are set together: the failed status
    /// the feed shows, and the queue entry that "send again" turns back on.
    static func markSendFailed(_ dbc: GRDB.Database, clientMsgId: String, reason: String) throws {
        try dbc.execute(sql: "UPDATE outbox SET state = 'failed' WHERE clientMsgId = ?",
                        arguments: [clientMsgId])
        try dbc.execute(
            sql: "UPDATE message SET status = ?, failReason = ? WHERE clientMsgId = ?",
            arguments: [MessageStatus.failed.rawValue, reason, clientMsgId])
    }

    /// Sends a message that failed once more, from the payload it was written
    /// with. A message whose queue entry is gone — one this device failed before
    /// the entry was kept — cannot be repeated and says so by staying failed.
    @discardableResult
    public func retrySend(messageId: String) async -> Bool {
        let restored = (try? await db.write { dbc -> Bool in
            guard let clientMsgId = try String.fetchOne(
                dbc, sql: "SELECT clientMsgId FROM message WHERE id = ? OR clientMsgId = ?",
                arguments: [messageId, messageId]),
                try Bool.fetchOne(dbc, sql: "SELECT EXISTS(SELECT 1 FROM outbox WHERE clientMsgId = ?)",
                                  arguments: [clientMsgId]) == true
            else { return false }
            try dbc.execute(
                sql: "UPDATE outbox SET state = 'ready', attempts = 0 WHERE clientMsgId = ?",
                arguments: [clientMsgId])
            try dbc.execute(
                sql: """
                UPDATE message SET status = ?, failReason = NULL WHERE clientMsgId = ?
                """,
                arguments: [MessageStatus.sending.rawValue, clientMsgId])
            return true
        }) ?? false
        if restored { wakeOutbox() }
        return restored
    }

    private func applyReceipt(_ f: WSIncoming) async {
        guard let chatId = f.chatId, let by = f.by, by != ownUserId else { return }
        let upTo = f.upToSeq ?? f.seqs?.max() ?? 0
        guard upTo > 0 else { return }
        let isRead = f.kind == "read"
        try? await db.write { [ownUserId] dbc in
            try SyncEngine.recordMark(dbc, chatId: chatId, userId: by, upToSeq: upTo, isRead: isRead)
            try SyncEngine.applyPeerMarks(dbc, chatId: chatId, ownUserId: ownUserId)
        }
    }

    /// One member's mark. Both marks only ever move forward: a receipt that
    /// arrives out of order says nothing new.
    static func recordMark(_ dbc: GRDB.Database, chatId: String, userId: String,
                           upToSeq: Int, isRead: Bool) throws {
        let column = isRead ? "readUpTo" : "deliveredUpTo"
        try dbc.execute(
            sql: """
            INSERT INTO chatMark (chatId, userId, deliveredUpTo, readUpTo) VALUES (?,?,?,?)
            ON CONFLICT(chatId, userId) DO UPDATE SET \(column) = MAX(chatMark.\(column), excluded.\(column))
            """,
            arguments: [chatId, userId, isRead ? 0 : upToSeq, isRead ? upToSeq : 0])
        // reading is having received: a read mark implies the delivery below it
        if isRead {
            try dbc.execute(
                sql: """
                UPDATE chatMark SET deliveredUpTo = MAX(deliveredUpTo, ?)
                WHERE chatId = ? AND userId = ?
                """, arguments: [upToSeq, chatId, userId])
        }
    }

    /// The tick speaks for the whole chat, so it moves on the member who is
    /// furthest behind: in a group the second tick appears when the last member
    /// has the message, and it turns read when the last of them has read it. In
    /// a direct chat that member is the only one there is.
    ///
    /// A member who joined later has no marks and holds the chat's ticks where
    /// they are; the ones already given out stay, both cursors and the message
    /// status only move up.
    static func applyPeerMarks(_ dbc: GRDB.Database, chatId: String, ownUserId: String) throws {
        guard let row = try Row.fetchOne(dbc, sql: """
            SELECT COUNT(*) AS peers,
                   MIN(COALESCE(k.deliveredUpTo, 0)) AS delivered,
                   MIN(COALESCE(k.readUpTo, 0)) AS read
            FROM member m
            LEFT JOIN chatMark k ON k.chatId = m.chatId AND k.userId = m.userId
            WHERE m.chatId = ? AND m.userId <> ?
            """, arguments: [chatId, ownUserId]), (row["peers"] as Int) > 0 else { return }
        let delivered: Int = row["delivered"]
        let read: Int = row["read"]
        try dbc.execute(
            sql: """
            UPDATE chat SET peerDeliveredUpTo = MAX(peerDeliveredUpTo, ?),
                            peerReadUpTo = MAX(peerReadUpTo, ?)
            WHERE id = ?
            """, arguments: [delivered, read, chatId])
        if read > 0 {
            try dbc.execute(
                sql: "UPDATE message SET status = 3 WHERE chatId = ? AND isOutgoing = 1 AND seq <= ? AND status < 3",
                arguments: [chatId, read])
        }
        if delivered > 0 {
            try dbc.execute(
                sql: "UPDATE message SET status = 2 WHERE chatId = ? AND isOutgoing = 1 AND seq <= ? AND status < 2",
                arguments: [chatId, delivered])
        }
    }

    // MARK: - Sending

    /// Content kinds with no feed row of their own; they go out service-flagged.
    public static let serviceKinds: Set<String> = Set(["edit", "reaction", "disappearing"])
        .union(SyncEngine.repairKinds)

    /// The only way out: writes the row and the outbox entry, wakes the worker,
    /// works offline. clientMsgId is passed in where a repeat has to collapse
    /// under the server's dedup (a repair request, its answer, a chain ack).
    public func enqueue(content: ContentPayload, chatId: String,
                        clientMsgId: String = UUID().uuidString) async throws {
        let now = Date().timeIntervalSince1970
        var msg = Message(id: clientMsgId, chatId: chatId, fromUserId: ownUserId, sentAt: now,
                          kind: MessageKind(rawValue: content.kind) ?? .text,
                          text: content.text, status: .sending, isOutgoing: true)
        msg.clientMsgId = clientMsgId
        msg.media = content.media
        msg.album = content.album
        msg.replyTo = content.replyTo
        msg.forward = content.fwd
        let payload = try JSONEncoder().encode(content)
        try await db.write { [msg] dbc in
            let visible = !SyncEngine.serviceKinds.contains(content.kind)
            if visible { try msg.save(dbc) }
            try OutboxItem(clientMsgId: clientMsgId, chatId: chatId, createdAt: now, payload: payload).save(dbc)
            if visible {
                try dbc.execute(sql: "UPDATE chat SET lastActivityAt = ? WHERE id = ?", arguments: [now, chatId])
            }
            // an edit takes effect here before it is sent
            if content.kind == "edit", let target = content.targetMsgId {
                try dbc.execute(sql: "UPDATE message SET text = ?, edited = 1 WHERE chatId = ? AND (msgId = ? OR id = ?)",
                                arguments: [content.text, chatId, target, target])
            }
            if content.kind == "reaction", let target = content.targetMsgId {
                try SyncEngine.applyReaction(dbc, chatId: chatId, targetMsgId: target,
                                             userId: self.ownUserId, emoji: content.emoji)
            }
        }
        outboxWakeup.continuation.yield()
    }

    private func wakeOutbox() {
        outboxWakeup.continuation.yield()
    }

    private var draining = false

    private func drainOutbox() async {
        guard connected, !draining else { return }
        draining = true
        defer { draining = false }
        while connected {
            guard let item = (try? await db.read { dbc in
                try OutboxItem.fetchOne(
                    dbc, sql: "SELECT * FROM outbox WHERE state = 'ready' ORDER BY createdAt LIMIT 1")
            }) ?? nil else { break }

            do {
                try await sendOutboxItem(item)
            } catch {
                // TOFU: the recipient's identity key changed, so sending stops
                // until the user accepts it and the message shows as failed
                // (the chat banner offers that choice)
                if let ee = error as? E2EEError, case .identityChanged(let uid) = ee {
                    try? await db.write { dbc in
                        try dbc.execute(sql: "UPDATE outbox SET state = 'blocked' WHERE clientMsgId = ?",
                                        arguments: [item.clientMsgId])
                        try dbc.execute(
                            sql: "UPDATE message SET status = -1, failReason = ? WHERE clientMsgId = ?",
                            arguments: [SendFailure.identityChanged, item.clientMsgId])
                    }
                    await insertSystemMessage(chatId: item.chatId, text: "identity_changed:\(uid)")
                    continue
                }
                // an edit or a reaction outran its target's ack: it waits for it
                // without holding up the queue or spending an attempt
                if let t = error as? TargetNotAcked {
                    try? await db.write { dbc in
                        try dbc.execute(
                            sql: t.gone
                                ? "DELETE FROM outbox WHERE clientMsgId = ?"
                                : "UPDATE outbox SET state = 'waiting' WHERE clientMsgId = ?",
                            arguments: [item.clientMsgId])
                    }
                    continue
                }
                // count the attempt; on a network error stop here, the
                // reconnect wakes the drain again
                try? await db.write { dbc in
                    try dbc.execute(sql: "UPDATE outbox SET attempts = attempts + 1 WHERE clientMsgId = ?",
                                    arguments: [item.clientMsgId])
                }
                let attempts = item.attempts + 1
                if attempts > 10 {
                    try? await db.write { dbc in
                        try SyncEngine.markSendFailed(dbc, clientMsgId: item.clientMsgId,
                                                      reason: SendFailure.tooManyAttempts)
                    }
                    continue
                }
                break
            }
        }
    }

    /// The target of a service frame has no server msgId: either the ack has not
    /// arrived yet (`gone == false`, we wait for it), or the message never went out.
    struct TargetNotAcked: Error { let gone: Bool }

    private func sendOutboxItem(_ item: OutboxItem) async throws {
        var content = try JSONDecoder().decode(ContentPayload.self, from: item.payload)
        // media attached offline is uploaded before the envelope is encrypted;
        // a network error here is an ordinary outbox retry
        content = try await uploadPendingMedia(content, item: item)
        content = try await resolveTarget(content, chatId: item.chatId)
        let info = try await db.read { dbc -> (kind: String, members: [String])? in
            guard let chat = try Chat.fetchOne(dbc, key: item.chatId) else { return nil }
            let members = try String.fetchAll(dbc, sql: "SELECT userId FROM member WHERE chatId = ?",
                                              arguments: [item.chatId])
            return (chat.kind.rawValue, members)
        }
        guard let info else {
            try? await db.write { dbc in
                try dbc.execute(sql: "DELETE FROM outbox WHERE clientMsgId = ?", arguments: [item.clientMsgId])
            }
            return
        }

        let service = Self.serviceKinds.contains(content.kind)
        if let addressee = content.to {
            // an addressed frame (a repair request, a copy, a chain ack)
            // concerns two devices, so it goes pairwise even in a group
            let env = try await e2ee.encryptDirect(content: content, toUserId: addressee)
            try await ws.send(.send(chatId: item.chatId, clientMsgId: item.clientMsgId,
                                    sentAt: item.createdAt, body: env, service: service))
        } else if info.kind == "direct" {
            let peer = info.members.first { $0 != ownUserId } ?? ownUserId
            let env = try await e2ee.encryptDirect(content: content, toUserId: peer)
            try await ws.send(.send(chatId: item.chatId, clientMsgId: item.clientMsgId,
                                    sentAt: item.createdAt, body: env, service: service))
        } else {
            let (skd, skdId, skm) = try await e2ee.encryptGroup(content: content, chatId: item.chatId,
                                                                memberIds: info.members)
            if let skd, let skdId {
                try await ws.send(.send(chatId: item.chatId, clientMsgId: skdId,
                                        sentAt: item.createdAt, body: skd, service: true))
            }
            try await ws.send(.send(chatId: item.chatId, clientMsgId: item.clientMsgId,
                                    sentAt: item.createdAt, body: skm, service: service))
        }
        // the outbox row goes on the "sent" ack; here it is only marked in
        // flight. attempts stays put: a frame that left without an ack yet is
        // not a failed attempt
        try await db.write { dbc in
            try dbc.execute(sql: "UPDATE outbox SET state = 'inflight' WHERE clientMsgId = ?",
                            arguments: [item.clientMsgId])
        }
        // safety net: no ack within 15s puts the item back to ready and wakes
        // the sender
        Task { [weak self, db, clientMsgId = item.clientMsgId] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            let reverted = (try? await db.write { dbc -> Bool in
                try dbc.execute(sql: "UPDATE outbox SET state = 'ready' WHERE clientMsgId = ? AND state = 'inflight'",
                                arguments: [clientMsgId])
                return dbc.changesCount > 0
            }) ?? false
            if reverted { await self?.wakeOutbox() }
        }
    }

    /// An edit and a reaction point at a message by id, and for our own message that
    /// id is local until the ack: the peer has no such row, and the event would settle
    /// in their `pendingApply` under an id that never arrives. The target is resolved
    /// at send time; until the ack is in, there is nothing to send.
    func resolveTarget(_ content: ContentPayload, chatId: String) async throws -> ContentPayload {
        guard let target = content.targetMsgId else { return content }
        let row = try await db.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT msgId, status FROM message WHERE chatId = ? AND id = ?",
                             arguments: [chatId, target])
        }
        // no row — the id is already a server one (the target came from the peer)
        guard let row else { return content }
        guard let serverId = row["msgId"] as String? else {
            // the target never went out: there is nothing on the server to react to
            throw TargetNotAcked(gone: (row["status"] as Int?) == MessageStatus.failed.rawValue)
        }
        var resolved = content
        resolved.targetMsgId = serverId
        return resolved
    }

    // MARK: - Uploading local media before sending

    struct MediaManagerMissing: Error {}

    /// Uploads attachments that still have a local source (empty mediaId, file
    /// in pendingDir). After each item the updated payload is written to the
    /// outbox and to the message row, so being killed mid-way does not upload
    /// again what already went up.
    private func uploadPendingMedia(_ content: ContentPayload, item: OutboxItem) async throws -> ContentPayload {
        func needsUpload(_ i: MediaInfo) -> Bool { i.mediaId.isEmpty && i.localPath != nil }
        var content = content
        if let m = content.media, needsUpload(m) {
            let (uploaded, obsolete) = try await uploadOne(m)
            content.media = uploaded
            try await persistUploadedPayload(content, clientMsgId: item.clientMsgId)
            obsolete.forEach { media?.removePending(localName: $0) }
        }
        if var album = content.album, album.contains(where: needsUpload) {
            for idx in album.indices where needsUpload(album[idx]) {
                let (uploaded, obsolete) = try await uploadOne(album[idx])
                album[idx] = uploaded
                content.album = album
                try await persistUploadedPayload(content, clientMsgId: item.clientMsgId)
                obsolete.forEach { media?.removePending(localName: $0) }
            }
        }
        return content
    }

    private func uploadOne(_ info: MediaInfo) async throws -> (MediaInfo, obsoleteLocal: [String]) {
        guard let media else { throw MediaManagerMissing() }
        var info = info
        var obsolete: [String] = []
        if info.thumbMediaId == nil, let thumbName = info.thumbLocalPath {
            let up = try await media.uploadPending(localName: thumbName, mime: "image/jpeg")
            info.thumbMediaId = up.mediaId
            info.thumbKey = up.key
            info.thumbHash = up.hash
            info.thumbLocalPath = nil
            obsolete.append(thumbName)
        }
        if let name = info.localPath {
            let up = try await media.uploadPending(localName: name, mime: info.mime)
            info.mediaId = up.mediaId
            info.key = up.key
            info.hash = up.hash
            info.size = up.size
            info.localPath = nil
            obsolete.append(name)
        }
        return (info, obsolete)
    }

    private func persistUploadedPayload(_ content: ContentPayload, clientMsgId: String) async throws {
        let enc = JSONEncoder()
        let payload = try enc.encode(content)
        let mediaJSON = content.media.flatMap { try? enc.encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        let albumJSON = content.album.flatMap { try? enc.encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        try await db.write { dbc in
            try dbc.execute(sql: "UPDATE outbox SET payload = ? WHERE clientMsgId = ?",
                            arguments: [payload, clientMsgId])
            try dbc.execute(sql: "UPDATE message SET media = ?, album = ? WHERE clientMsgId = ?",
                            arguments: [mediaJSON, albumJSON, clientMsgId])
        }
    }

    // MARK: - Action queue (read / delete-for-all / accept)

    struct ReadActionPayload: Codable { var upToSeq: Int }
    struct DeleteActionPayload: Codable { var msgIds: [String]; var forAll: Bool }
    struct BlockActionPayload: Codable { var userId: String; var blocked: Bool }

    /// Read actions collapse per chat: one row per chatId, the larger upToSeq wins.
    static func upsertReadAction(_ dbc: GRDB.Database, chatId: String, upToSeq: Int) throws {
        let id = "read:\(chatId)"
        let prev = try Row.fetchOne(dbc, sql: "SELECT payload FROM pendingAction WHERE id = ?", arguments: [id])
            .flatMap { row -> ReadActionPayload? in
                try? JSONDecoder().decode(ReadActionPayload.self, from: Data((row["payload"] as String).utf8))
            }?.upToSeq ?? 0
        let payload = String(data: try JSONEncoder().encode(ReadActionPayload(upToSeq: max(prev, upToSeq))),
                             encoding: .utf8)!
        try dbc.execute(
            sql: """
            INSERT INTO pendingAction (id, type, chatId, payload, createdAt) VALUES (?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, attempts = 0
            """,
            arguments: [id, "read", chatId, payload, Date().timeIntervalSince1970])
    }

    private var drainingActions = false

    /// Drains the action queue in order; a network error stops the drain and
    /// the reconnect wakes it again.
    private func drainActions() async {
        guard connected, !drainingActions else { return }
        drainingActions = true
        defer { drainingActions = false }
        while connected {
            guard let a = (try? await db.read { dbc in
                try PendingAction.fetchOne(dbc, sql: "SELECT * FROM pendingAction ORDER BY createdAt LIMIT 1")
            }) ?? nil else { break }
            do {
                switch a.type {
                case "read":
                    let p = try JSONDecoder().decode(ReadActionPayload.self, from: Data(a.payload.utf8))
                    try await ws.send(.read(chatId: a.chatId ?? "", upToSeq: p.upToSeq))
                case DeliveryReceipts.actionType:
                    // a receipt this device owes: for a message off the socket,
                    // or one the notification extension wrote and could not send
                    let p = try JSONDecoder().decode(DeliveryReceipts.Payload.self,
                                                     from: Data(a.payload.utf8))
                    try await ws.send(.recv(chatId: a.chatId ?? "", seqs: [p.upToSeq]))
                case "delete":
                    let p = try JSONDecoder().decode(DeleteActionPayload.self, from: Data(a.payload.utf8))
                    try await ws.send(.delete(chatId: a.chatId ?? "", msgIds: p.msgIds, forAll: p.forAll))
                case "accept":
                    try await api.acceptChat(a.chatId ?? "")
                case "deleteChat":
                    try await api.deleteChat(a.chatId ?? "")
                case "block":
                    let p = try JSONDecoder().decode(BlockActionPayload.self, from: Data(a.payload.utf8))
                    try await api.setBlocked(p.userId, blocked: p.blocked)
                default:
                    break // an unknown type is dropped below
                }
                try? await db.write { [a] dbc in
                    // a read may have collapsed with a larger upToSeq while
                    // this one was in flight: the payload then differs and the
                    // row stays behind to be sent again
                    try dbc.execute(sql: "DELETE FROM pendingAction WHERE id = ? AND payload = ?",
                                    arguments: [a.id, a.payload])
                }
            } catch {
                let attempts = a.attempts + 1
                try? await db.write { [a] dbc in
                    if attempts > 20 {
                        try dbc.execute(sql: "DELETE FROM pendingAction WHERE id = ?", arguments: [a.id])
                    } else {
                        try dbc.execute(sql: "UPDATE pendingAction SET attempts = ? WHERE id = ?",
                                        arguments: [attempts, a.id])
                    }
                }
                break
            }
        }
    }

    // MARK: - User actions

    /// Accepts the new identity keys of the chat's members and resends the blocked
    /// messages. The key may have changed for any member of a group, so every member
    /// whose key is awaiting confirmation in this chat is accepted.
    public func acceptKeyChange(chatId: String) async {
        let pending: [String] = (try? await db.read { dbc in
            try String.fetchAll(dbc, sql: """
                SELECT t.userId FROM trustedIdentity t
                JOIN member m ON m.userId = t.userId
                WHERE m.chatId = ? AND t.changedPending IS NOT NULL
                """, arguments: [chatId])
        }) ?? []
        for userId in pending { try? e2ee.acceptChangedIdentity(userId: userId) }
        try? await db.write { dbc in
            try dbc.execute(sql: """
                UPDATE message SET status = 0, failReason = NULL WHERE clientMsgId IN
                (SELECT clientMsgId FROM outbox WHERE chatId = ? AND state = 'blocked')
                """, arguments: [chatId])
            try dbc.execute(sql: "UPDATE outbox SET state = 'ready' WHERE chatId = ? AND state = 'blocked'",
                            arguments: [chatId])
        }
        wakeOutbox()
    }

    /// An unaccepted request is never marked read: the author must not learn
    /// that the recipient opened the chat (the server drops such a mark too).
    public func markRead(chatId: String, upToSeq: Int) async {
        let isRequest = (try? await db.read { dbc in
            try Bool.fetchOne(dbc, sql: "SELECT isRequest FROM chat WHERE id = ?", arguments: [chatId]) ?? false
        }) ?? false
        guard !isRequest else { return }
        try? await db.write { dbc in
            try dbc.execute(sql: "UPDATE chat SET myReadUpTo = MAX(myReadUpTo, ?), unreadCount = 0 WHERE id = ?",
                            arguments: [upToSeq, chatId])
            try SyncEngine.upsertReadAction(dbc, chatId: chatId, upToSeq: upToSeq)
        }
        actionWakeup.continuation.yield()
    }

    /// Accepting a request: locally at once, the server accept through the
    /// action queue.
    public func acceptChatRequest(chatId: String) async {
        try? await db.write { dbc in
            try dbc.execute(sql: "UPDATE chat SET isRequest = 0, iAccepted = 1 WHERE id = ?",
                            arguments: [chatId])
            try dbc.execute(
                sql: """
                INSERT INTO pendingAction (id, type, chatId, payload, createdAt) VALUES (?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET attempts = 0
                """,
                arguments: ["accept:\(chatId)", "accept", chatId, "{}", Date().timeIntervalSince1970])
        }
        actionWakeup.continuation.yield()
    }

    /// Empties a chat this device stays in. Nothing leaves the device: the
    /// ratchet is forward-only, the copy here is the only one this device has,
    /// and the other side keeps its own.
    public func clearHistory(chatId: String) async {
        let attachments = await chatMedia(chatId: chatId)
        try? await db.write { dbc in
            try ChatCleanup.clearHistory(dbc, chatId: chatId)
        }
        for info in attachments { media?.remove(info) }
    }

    /// Removes a chat from this device. The server is told through the action
    /// queue, so the chat goes now and the request survives being offline; the
    /// snapshot leaves the chat out while that request is pending, otherwise it
    /// would come straight back.
    public func deleteChat(chatId: String) async {
        let attachments = await chatMedia(chatId: chatId)
        try? await db.write { dbc in
            try ChatCleanup.deleteChat(dbc, chatId: chatId)
            try dbc.execute(
                sql: """
                INSERT INTO pendingAction (id, type, chatId, payload, createdAt) VALUES (?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET attempts = 0
                """,
                arguments: ["deleteChat:\(chatId)", "deleteChat", chatId, "{}",
                            Date().timeIntervalSince1970])
        }
        for info in attachments { media?.remove(info) }
        actionWakeup.continuation.yield()
    }

    /// Attachments stored for a chat, so their files go with its rows.
    private func chatMedia(chatId: String) async -> [MediaInfo] {
        let msgs = (try? await db.read { dbc in
            try Message.fetchAll(dbc, sql: "SELECT * FROM message WHERE chatId = ?",
                                 arguments: [chatId])
        }) ?? []
        return msgs.flatMap { ($0.media.map { [$0] } ?? []) + ($0.album ?? []) }
    }

    /// Chats whose deletion has not reached the server yet.
    private func chatsBeingDeleted() async -> Set<String> {
        (try? await db.read { dbc in
            try String.fetchSet(dbc, sql: "SELECT chatId FROM pendingAction WHERE type = 'deleteChat'")
        }) ?? []
    }

    public func sendTyping(chatId: String, kind: String?) async {
        try? await ws.send(.typing(chatId: chatId, kind: kind))
    }

    public func deleteMessages(chatId: String, msgIds: [String], forAll: Bool) async {
        try? await db.write { dbc in
            for id in msgIds {
                if forAll {
                    try dbc.execute(
                        sql: "UPDATE message SET deletedForAll = 1, text = NULL, media = NULL, album = NULL WHERE chatId = ? AND (msgId = ? OR id = ?)",
                        arguments: [chatId, id, id])
                } else {
                    // a message thrown away is not sent afterwards: its queue
                    // entry goes with it, whether it is still waiting for its
                    // turn or holding the payload of a send that failed
                    try dbc.execute(sql: """
                        DELETE FROM outbox WHERE clientMsgId IN
                          (SELECT clientMsgId FROM message
                           WHERE chatId = ? AND (msgId = ? OR id = ?) AND clientMsgId IS NOT NULL)
                        """, arguments: [chatId, id, id])
                    try dbc.execute(sql: "DELETE FROM message WHERE chatId = ? AND (msgId = ? OR id = ?)",
                                    arguments: [chatId, id, id])
                }
            }
        }
        if forAll {
            try? await db.write { dbc in
                let payload = String(data: try JSONEncoder().encode(DeleteActionPayload(msgIds: msgIds, forAll: true)),
                                     encoding: .utf8)!
                try dbc.execute(
                    sql: "INSERT INTO pendingAction (id, type, chatId, payload, createdAt) VALUES (?,?,?,?,?)",
                    arguments: [UUID().uuidString, "delete", chatId, payload, Date().timeIntervalSince1970])
            }
            actionWakeup.continuation.yield()
        }
    }

    // MARK: - Shared upserts

    static func upsertUser(_ dbc: GRDB.Database, _ u: APIClient.UserDTO) throws {
        try dbc.execute(
            sql: """
            INSERT INTO user (id, username, displayName, bio, avatarId)
            VALUES (?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET username = excluded.username,
              displayName = excluded.displayName, bio = excluded.bio, avatarId = excluded.avatarId
            """,
            arguments: [u.id, u.username, u.display_name, u.bio, u.avatar_id])
    }

    /// A chat's local flags, as the server snapshot carries them.
    public struct ChatFlags: Sendable {
        public let pinned: Bool
        public let muted: Bool
        public let mutedUntil: Double?
        public let archived: Bool
        public init(pinned: Bool, muted: Bool, mutedUntil: Double?, archived: Bool) {
            self.pinned = pinned
            self.muted = muted
            self.mutedUntil = mutedUntil
            self.archived = archived
        }
    }

    static func upsertChatState(_ dbc: GRDB.Database, _ s: ChatStateDTO, ownUserId: String,
                                flags: ChatFlags?) throws {
        let me = s.members.first { $0.userId == ownUserId }
        let iAccepted = me?.accepted ?? true
        let isRequest = s.kind == "direct" && !iAccepted
        let myRead = s.readMarks[ownUserId] ?? 0
        // a chat this device deleted and got back starts at the position its
        // tombstone kept, so the catch-up resumes instead of replaying a
        // journal whose keys are gone
        let resume = try ChatCleanup.tombstoneSeq(dbc, chatId: s.chatId)
        try dbc.execute(
            sql: """
            INSERT INTO chat (id, kind, title, avatarId, chatDescription, createdBy, createdAt,
                              pinnedMsgId, lastSeq, syncedSeq, syncCursor, myReadUpTo, peerReadUpTo,
                              peerDeliveredUpTo, lastActivityAt, isRequest, iAccepted, pinned, muted,
                              archived, unreadCount)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
              title = excluded.title, avatarId = excluded.avatarId,
              chatDescription = excluded.chatDescription, pinnedMsgId = excluded.pinnedMsgId,
              lastSeq = MAX(chat.lastSeq, excluded.lastSeq),
              myReadUpTo = MAX(chat.myReadUpTo, excluded.myReadUpTo),
              peerReadUpTo = MAX(chat.peerReadUpTo, excluded.peerReadUpTo),
              peerDeliveredUpTo = MAX(chat.peerDeliveredUpTo, excluded.peerDeliveredUpTo),
              -- acceptance is one-way: a local accept is not rolled back by a
              -- snapshot the server built before our /accept reached it
              isRequest = MIN(chat.isRequest, excluded.isRequest),
              iAccepted = MAX(chat.iAccepted, excluded.iAccepted),
              unreadCount = MAX(0, MAX(chat.lastSeq, excluded.lastSeq) - MAX(chat.myReadUpTo, excluded.myReadUpTo))
            """,
            arguments: [s.chatId, s.kind, s.title, s.avatarId, s.description, s.createdBy,
                        s.createdAt, s.pinnedMsgId, s.lastSeq, resume, resume,
                        max(myRead, resume), 0, 0,
                        s.createdAt, isRequest, iAccepted,
                        flags?.pinned ?? false, flags?.muted ?? false, flags?.archived ?? false,
                        max(0, s.lastSeq - max(myRead, resume))])
        if let flags {
            try dbc.execute(
                sql: "UPDATE chat SET pinned = ?, muted = ?, mutedUntil = ?, archived = ? WHERE id = ?",
                arguments: [flags.pinned, flags.muted, flags.mutedUntil, flags.archived, s.chatId])
        }
        try dbc.execute(sql: "DELETE FROM member WHERE chatId = ?", arguments: [s.chatId])
        for m in s.members {
            try ChatMemberRow(chatId: s.chatId, userId: m.userId, role: m.role, joinedAt: m.joinedAt).save(dbc)
        }
        // the snapshot carries where every member stands, and the ticks of the
        // chat are recomputed from them once the member list is the current one
        for (userId, upTo) in s.deliveredMarks {
            try recordMark(dbc, chatId: s.chatId, userId: userId, upToSeq: upTo, isRead: false)
        }
        for (userId, upTo) in s.readMarks {
            try recordMark(dbc, chatId: s.chatId, userId: userId, upToSeq: upTo, isRead: true)
        }
        try applyPeerMarks(dbc, chatId: s.chatId, ownUserId: ownUserId)
    }

    /// Returns false when the target message is not stored and the reaction
    /// went nowhere.
    @discardableResult
    static func applyReaction(_ dbc: GRDB.Database, chatId: String, targetMsgId: String,
                              userId: String, emoji: String?) throws -> Bool {
        guard let row = try Row.fetchOne(
            dbc, sql: "SELECT id, reactions FROM message WHERE chatId = ? AND (msgId = ? OR id = ?)",
            arguments: [chatId, targetMsgId, targetMsgId]) else { return false }
        var reactions = (try? JSONDecoder().decode([String: [String]].self,
                                                   from: Data((row["reactions"] as String).utf8))) ?? [:]
        // one reaction per user: drop him from every emoji, then add the new one
        for (k, users) in reactions {
            reactions[k] = users.filter { $0 != userId }
            if reactions[k]?.isEmpty == true { reactions.removeValue(forKey: k) }
        }
        if let emoji {
            reactions[emoji, default: []].append(userId)
        }
        let json = String(data: try JSONEncoder().encode(reactions), encoding: .utf8)!
        try dbc.execute(sql: "UPDATE message SET reactions = ? WHERE id = ?",
                        arguments: [json, row["id"] as String])
        return true
    }

    // MARK: - Buffer for edit/reaction/deleted with no original yet

    static func payloadJSON(_ content: ContentPayload) -> String {
        (try? JSONEncoder().encode(content)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Holds an edit, reaction or delete whose target message is not stored
    /// yet. A repeat from the same author replaces the row, so the last one wins.
    static func bufferPendingApply(_ dbc: GRDB.Database, chatId: String, targetMsgId: String,
                                   kind: String, fromUserId: String, payload: String, seq: Int?) throws {
        try dbc.execute(
            sql: """
            INSERT OR REPLACE INTO pendingApply (chatId, targetMsgId, kind, fromUserId, payload, seq)
            VALUES (?,?,?,?,?,?)
            """,
            arguments: [chatId, targetMsgId, kind, fromUserId, payload, seq])
    }

    /// Applies the held edits, reactions and deletes to a message that has just
    /// been inserted.
    static func applyBuffered(_ dbc: GRDB.Database, chatId: String, msgId: String) throws {
        let rows = try Row.fetchAll(
            dbc, sql: "SELECT kind, fromUserId, payload FROM pendingApply WHERE chatId = ? AND targetMsgId = ? ORDER BY seq",
            arguments: [chatId, msgId])
        guard !rows.isEmpty else { return }
        let dec = JSONDecoder()
        for row in rows {
            let content = try? dec.decode(ContentPayload.self, from: Data((row["payload"] as String).utf8))
            switch row["kind"] as String {
            case "edit":
                if let content {
                    try dbc.execute(
                        sql: "UPDATE message SET text = ?, edited = 1 WHERE chatId = ? AND msgId = ?",
                        arguments: [content.text, chatId, msgId])
                }
            case "reaction":
                if let content {
                    try applyReaction(dbc, chatId: chatId, targetMsgId: msgId,
                                      userId: row["fromUserId"], emoji: content.emoji)
                }
            case "deleted":
                try dbc.execute(
                    sql: """
                    UPDATE message SET deletedForAll = 1, text = NULL, media = NULL,
                    album = NULL, kind = 'text' WHERE chatId = ? AND msgId = ?
                    """,
                    arguments: [chatId, msgId])
            default:
                break
            }
        }
        try dbc.execute(sql: "DELETE FROM pendingApply WHERE chatId = ? AND targetMsgId = ?",
                        arguments: [chatId, msgId])
    }
}
