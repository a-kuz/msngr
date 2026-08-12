import Foundation
import GRDB
import MsngrCrypto

/// Оркестратор: WS ↔ БД ↔ E2EE. UI никогда не ждёт сеть — читает только БД.
public actor SyncEngine {
    public let db: DatabaseQueue
    public let api: APIClient
    public let e2ee: E2EEManager
    private let ws: WSClient
    public let ownUserId: String
    public let ownDeviceId: String

    private var eventTask: Task<Void, Never>?
    private var outboxTask: Task<Void, Never>?
    private var outboxWakeup = AsyncStream<Void>.makeStream()
    private var connected = false

    /// typing-события не пишутся в БД — транслируются подписчикам UI
    public private(set) var typingStream = AsyncStream<(chatId: String, userId: String, kind: String?)>.makeStream()

    public init(db: DatabaseQueue, api: APIClient, e2ee: E2EEManager,
                wsURL: URL, ownUserId: String, ownDeviceId: String) {
        self.db = db
        self.api = api
        self.e2ee = e2ee
        self.ws = WSClient(url: wsURL)
        self.ownUserId = ownUserId
        self.ownDeviceId = ownDeviceId
    }

    // MARK: - Lifecycle

    public func start() async {
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
        // начальный снапшот — не блокирует UI, БД уже показывает старое
        Task { try? await self.refreshSnapshot() }
        Task { await self.replenishPrekeysIfNeeded() }
    }

    private var prekeysChecked = false

    /// Раз в сессию: если на сервере осталось < 20 своих one-time prekeys —
    /// догенерировать до 100 и дозалить.
    private func replenishPrekeysIfNeeded() async {
        guard !prekeysChecked else { return }
        prekeysChecked = true
        do {
            let remaining = try await api.prekeyCount()
            guard remaining < 20 else { return }
            let fresh = try e2ee.store.generateMoreOneTime(count: 100 - remaining)
            try await api.uploadPrekeys(fresh.map {
                .init(id: $0.id, key: $0.key.publicKey.rawRepresentation.base64urlEncodedString())
            })
        } catch {
            prekeysChecked = false // сети не было — проверим при следующем start()
        }
    }

    public func stop() async {
        eventTask?.cancel()
        outboxTask?.cancel()
        await ws.stop()
        connected = false
    }

    private func handle(_ ev: WSEvent) async {
        switch ev {
        case .connected:
            connected = true
            await sendSyncCursors()
            outboxWakeup.continuation.yield()
        case .disconnected:
            connected = false
        case .frame(let data):
            guard let frame = try? JSONDecoder().decode(WSIncoming.self, from: data) else { return }
            await apply(frame)
        }
    }

    // MARK: - Снапшот и sync

    public func refreshSnapshot() async throws {
        let snap = try await api.chatsSnapshot()
        try await applySnapshot(snap)
        await sendSyncCursors()
    }

    private func applySnapshot(_ snap: APIClient.ChatsSnapshot) async throws {
        try await db.write { [ownUserId] dbc in
            for u in snap.users {
                try SyncEngine.upsertUser(dbc, u)
            }
            for entry in snap.chats {
                try SyncEngine.upsertChatState(dbc, entry.state, ownUserId: ownUserId,
                                               flags: (entry.flags.pinned, entry.flags.muted, entry.flags.archived))
            }
        }
    }

    private func sendSyncCursors() async {
        guard connected else { return }
        let cursors: [String: Int] = (try? await db.read { dbc in
            var out: [String: Int] = [:]
            for row in try Row.fetchAll(dbc, sql: "SELECT id, syncedSeq FROM chat") {
                out[row["id"]] = row["syncedSeq"]
            }
            return out
        }) ?? [:]
        try? await ws.send(.sync(cursors: cursors))
    }

    // MARK: - Применение входящих фреймов

    private func apply(_ f: WSIncoming) async {
        switch f.t {
        case "msg":
            await applyIncomingMessage(f)
        case "sent":
            await applySentAck(f)
        case "receipt":
            await applyReceipt(f)
        case "typing":
            if let chatId = f.chatId, let from = f.from {
                typingStream.continuation.yield((chatId, from, f.kind))
            }
        case "presence":
            if let userId = f.userId, let online = f.online {
                try? await db.write { dbc in
                    try dbc.execute(sql: "UPDATE user SET online = ?, lastSeen = ? WHERE id = ?",
                                    arguments: [online, f.lastSeen ?? 0, userId])
                }
            }
        case "chat":
            if let state = f.state {
                // старый состав фиксируем ДО перезаписи member-таблицы
                let previousMembers: [String] = (try? await db.read { dbc in
                    try String.fetchAll(dbc, sql: "SELECT userId FROM member WHERE chatId = ?", arguments: [state.chatId])
                }) ?? []
                try? await db.write { [ownUserId] dbc in
                    try SyncEngine.upsertChatState(dbc, state, ownUserId: ownUserId, flags: nil)
                }
                // выгнали из чата → чат удаляется локально
                if !state.members.contains(where: { $0.userId == ownUserId }) {
                    try? await db.write { dbc in
                        try dbc.execute(sql: "DELETE FROM chat WHERE id = ?", arguments: [state.chatId])
                    }
                }
                // кто-то покинул группу → ротация нашей sender-key цепочки,
                // чтобы ушедший не мог расшифровывать новые сообщения (forward secrecy)
                if f.event == "members", state.kind == "group" {
                    let current = Set(state.members.map(\.userId))
                    if !Set(previousMembers).subtracting(current).isEmpty {
                        try? e2ee.rotateSenderKey(chatId: state.chatId)
                    }
                }
            }
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
                    }
                }
            }
        default:
            break
        }
    }

    private var snapshotRefreshInFlight = false

    private func applyIncomingMessage(_ f: WSIncoming) async {
        guard let chatId = f.chatId, let msgId = f.msgId, let seq = f.seq,
              let from = f.from, let fromDevice = f.fromDevice else { return }

        // сообщение в неизвестный чат → мы пропустили создание чата, обновляем снапшот
        let chatKnown = (try? await db.read { dbc in
            try Bool.fetchOne(dbc, sql: "SELECT EXISTS(SELECT 1 FROM chat WHERE id = ?)", arguments: [chatId])
        }) ?? false
        if !chatKnown && !snapshotRefreshInFlight {
            snapshotRefreshInFlight = true
            try? await refreshSnapshot()
            snapshotRefreshInFlight = false
        }

        // моё собственное эхо с другого устройства или ack-путь — дедуп по msgId
        let exists = (try? await db.read { dbc in
            try Bool.fetchOne(dbc, sql: "SELECT EXISTS(SELECT 1 FROM message WHERE msgId = ?)", arguments: [msgId])
        }) ?? false

        if !exists, let body = f.body {
            let result: DecryptedIncoming
            if from == ownUserId && fromDevice == ownDeviceId {
                result = .undecryptable(reason: "own_echo") // своё сообщение уже в БД по clientMsgId
            } else {
                result = (try? e2ee.decrypt(envelopeJSON: body, chatId: chatId,
                                            fromUserId: from, fromDeviceId: fromDevice))
                    ?? .undecryptable(reason: "exception")
            }
            // сообщение раньше своего ключа → отложить и переиграть, когда ключ придёт
            if case .undecryptable(let reason) = result, Self.retryableReasons.contains(reason) {
                await savePending(chatId: chatId, msgId: msgId, seq: seq, from: from,
                                  fromDevice: fromDevice, sentAt: f.sentAt ?? 0, ts: f.ts ?? 0, body: body)
            } else {
                await storeIncoming(result, chatId: chatId, msgId: msgId, seq: seq,
                                    from: from, sentAt: f.sentAt ?? 0, ts: f.ts ?? 0)
                // получили контент/ключ → пробуем переиграть отложенные этого чата
                if case .undecryptable = result {} else {
                    await retryPending(chatId: chatId)
                }
            }
        }

        // курсор двигаем только по непрерывному префиксу (иначе потеряем историю в дыре);
        // lastSeq — серверный максимум; своё сообщение поднимает myReadUpTo;
        // непрочитанное = lastSeq - myReadUpTo (производное, не ручной инкремент)
        let isOwn = from == ownUserId
        try? await db.write { dbc in
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
        if from != ownUserId {
            try? await ws.send(.recv(chatId: chatId, seqs: [seq]))
        }
    }

    /// Причины, при которых расшифровка может удаться позже (ключ ещё не пришёл):
    /// групповое сообщение до sender-key, либо dr-сообщение раньше своего pk (reorder).
    static let retryableReasons: Set<String> = ["no_sender_key", "no_session"]

    private func savePending(chatId: String, msgId: String, seq: Int, from: String,
                             fromDevice: String, sentAt: Double, ts: Double, body: JSONValue) async {
        guard let data = try? JSONEncoder().encode(body) else { return }
        try? await db.write { dbc in
            try dbc.execute(
                sql: """
                INSERT OR IGNORE INTO pendingDecrypt (chatId, msgId, seq, fromUserId, fromDevice, sentAt, ts, body)
                VALUES (?,?,?,?,?,?,?,?)
                """,
                arguments: [chatId, msgId, seq, from, fromDevice, sentAt, ts, data])
        }
    }

    private func retryPending(chatId: String) async {
        struct Pending { let msgId: String; let seq: Int; let from: String; let fromDevice: String
                         let sentAt: Double; let ts: Double; let body: Data }
        let items: [Pending] = (try? await db.read { dbc in
            try Row.fetchAll(dbc, sql: "SELECT * FROM pendingDecrypt WHERE chatId = ? ORDER BY seq", arguments: [chatId])
                .map { Pending(msgId: $0["msgId"], seq: $0["seq"], from: $0["fromUserId"],
                               fromDevice: $0["fromDevice"], sentAt: $0["sentAt"], ts: $0["ts"], body: $0["body"]) }
        }) ?? []
        guard !items.isEmpty else { return }
        var madeProgress = false
        for item in items {
            guard let body = try? JSONDecoder().decode(JSONValue.self, from: item.body) else { continue }
            let result = (try? e2ee.decrypt(envelopeJSON: body, chatId: chatId,
                                            fromUserId: item.from, fromDeviceId: item.fromDevice))
                ?? .undecryptable(reason: "exception")
            if case .undecryptable(let reason) = result, Self.retryableReasons.contains(reason) {
                continue // ключа всё ещё нет
            }
            await storeIncoming(result, chatId: chatId, msgId: item.msgId, seq: item.seq,
                                from: item.from, sentAt: item.sentAt, ts: item.ts)
            try? await db.write { dbc in
                try dbc.execute(sql: "DELETE FROM pendingDecrypt WHERE chatId = ? AND msgId = ?",
                                arguments: [chatId, item.msgId])
            }
            madeProgress = true
        }
        // распространение sender-key могло разблокировать ещё сообщения
        if madeProgress { await retryPending(chatId: chatId) }
    }

    private func storeIncoming(_ result: DecryptedIncoming, chatId: String, msgId: String,
                               seq: Int, from: String, sentAt: Double, ts: Double) async {
        switch result {
        case .senderKeyDistribution:
            return // служебное, в ленту не попадает
        case .content(let content), .identityChanged(_, .some(let content)):
            await applyContent(content, chatId: chatId, msgId: msgId, seq: seq,
                               from: from, sentAt: sentAt, ts: ts)
            if case .identityChanged(let uid, _) = result {
                await insertSystemMessage(chatId: chatId, text: "identity_changed:\(uid)")
            }
        case .identityChanged(let uid, .none):
            await insertSystemMessage(chatId: chatId, text: "identity_changed:\(uid)")
        case .undecryptable(let reason):
            guard reason != "own_echo" else { return }
            var msg = Message(id: msgId, chatId: chatId, fromUserId: from, sentAt: sentAt,
                              kind: .system, text: "undecryptable", status: .sent, isOutgoing: false)
            msg.msgId = msgId
            msg.seq = seq
            msg.serverTs = ts
            try? await db.write { [msg] dbc in
                try msg.save(dbc)
            }
        }
    }

    private func applyContent(_ content: ContentPayload, chatId: String, msgId: String,
                              seq: Int, from: String, sentAt: Double, ts: Double) async {
        try? await db.write { [ownUserId] dbc in
            switch content.kind {
            case "edit":
                if let target = content.targetMsgId {
                    try dbc.execute(
                        sql: "UPDATE message SET text = ?, edited = 1 WHERE chatId = ? AND (msgId = ? OR id = ?)",
                        arguments: [content.text, chatId, target, target])
                }
            case "reaction":
                if let target = content.targetMsgId {
                    try SyncEngine.applyReaction(dbc, chatId: chatId, targetMsgId: target,
                                                 userId: from, emoji: content.emoji)
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
                // unreadCount пересчитывается в applyIncomingMessage как lastSeq - myReadUpTo
                try dbc.execute(sql: "UPDATE chat SET lastActivityAt = ? WHERE id = ?",
                                arguments: [max(ts, sentAt), chatId])
            }
        }
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
            try dbc.execute(
                sql: """
                UPDATE message SET msgId = ?, seq = ?, serverTs = ?, status = MAX(status, 1)
                WHERE clientMsgId = ?
                """,
                arguments: [msgId, seq, f.ts, clientMsgId])
            try dbc.execute(sql: "DELETE FROM outbox WHERE clientMsgId = ?", arguments: [clientMsgId])
            // своё отправленное считается прочитанным мной → myReadUpTo растёт, бейдж не копится
            try dbc.execute(
                sql: """
                UPDATE chat SET
                  syncedSeq = CASE WHEN ? = syncedSeq + 1 THEN ? ELSE syncedSeq END,
                  lastSeq = MAX(lastSeq, ?), myReadUpTo = MAX(myReadUpTo, ?),
                  lastActivityAt = ? WHERE id = ?
                """,
                arguments: [seq, seq, seq, seq, f.ts ?? Date().timeIntervalSince1970, chatId])
        }
    }

    private func applyReceipt(_ f: WSIncoming) async {
        guard let chatId = f.chatId, let by = f.by, by != ownUserId else { return }
        let upTo = f.upToSeq ?? f.seqs?.max() ?? 0
        guard upTo > 0 else { return }
        let isRead = f.kind == "read"
        try? await db.write { dbc in
            if isRead {
                try dbc.execute(sql: "UPDATE chat SET peerReadUpTo = MAX(peerReadUpTo, ?) WHERE id = ?",
                                arguments: [upTo, chatId])
                try dbc.execute(
                    sql: "UPDATE message SET status = 3 WHERE chatId = ? AND isOutgoing = 1 AND seq <= ? AND status < 3",
                    arguments: [chatId, upTo])
            } else {
                try dbc.execute(sql: "UPDATE chat SET peerDeliveredUpTo = MAX(peerDeliveredUpTo, ?) WHERE id = ?",
                                arguments: [upTo, chatId])
                try dbc.execute(
                    sql: "UPDATE message SET status = 2 WHERE chatId = ? AND isOutgoing = 1 AND seq <= ? AND status < 2",
                    arguments: [chatId, upTo])
            }
        }
    }

    // MARK: - Отправка

    /// Единственная точка отправки: пишет в БД + outbox, будит воркер. Работает офлайн.
    public func enqueue(content: ContentPayload, chatId: String) async throws {
        let clientMsgId = UUID().uuidString
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
            // edit/reaction/disappearing не создают своей строки в ленте
            let visible = !["edit", "reaction", "disappearing"].contains(content.kind)
            if visible { try msg.save(dbc) }
            try OutboxItem(clientMsgId: clientMsgId, chatId: chatId, createdAt: now, payload: payload).save(dbc)
            if visible {
                try dbc.execute(sql: "UPDATE chat SET lastActivityAt = ? WHERE id = ?", arguments: [now, chatId])
            }
            // edit применяем локально сразу
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
                // помечаем попытку; ошибка сети → выходим, реконнект разбудит снова
                try? await db.write { dbc in
                    try dbc.execute(sql: "UPDATE outbox SET attempts = attempts + 1 WHERE clientMsgId = ?",
                                    arguments: [item.clientMsgId])
                }
                let attempts = item.attempts + 1
                if attempts > 10 {
                    try? await db.write { dbc in
                        try dbc.execute(sql: "UPDATE message SET status = -1 WHERE clientMsgId = ?",
                                        arguments: [item.clientMsgId])
                        try dbc.execute(sql: "DELETE FROM outbox WHERE clientMsgId = ?",
                                        arguments: [item.clientMsgId])
                    }
                    continue
                }
                break
            }
        }
    }

    private func sendOutboxItem(_ item: OutboxItem) async throws {
        let content = try JSONDecoder().decode(ContentPayload.self, from: item.payload)
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

        if info.kind == "direct" {
            let peer = info.members.first { $0 != ownUserId } ?? ownUserId
            let env = try await e2ee.encryptDirect(content: content, toUserId: peer)
            try await ws.send(.send(chatId: item.chatId, clientMsgId: item.clientMsgId,
                                    sentAt: item.createdAt, body: env))
        } else {
            let (skd, skm) = try await e2ee.encryptGroup(content: content, chatId: item.chatId,
                                                         memberIds: info.members)
            if let skd {
                try await ws.send(.send(chatId: item.chatId, clientMsgId: UUID().uuidString,
                                        sentAt: item.createdAt, body: skd))
            }
            try await ws.send(.send(chatId: item.chatId, clientMsgId: item.clientMsgId,
                                    sentAt: item.createdAt, body: skm))
        }
        // outbox-строка удалится по "sent" ack; здесь только помечаем «в полёте».
        // attempts НЕ трогаем: успешная отправка без ack — не ошибка (сервер дедуплицирует повтор)
        try await db.write { dbc in
            try dbc.execute(sql: "UPDATE outbox SET state = 'inflight' WHERE clientMsgId = ?",
                            arguments: [item.clientMsgId])
        }
        // страховка: если ack не пришёл за 15с — вернуть в ready и разбудить отправку
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

    // MARK: - Пользовательские действия

    public func markRead(chatId: String, upToSeq: Int) async {
        try? await db.write { dbc in
            try dbc.execute(sql: "UPDATE chat SET myReadUpTo = MAX(myReadUpTo, ?), unreadCount = 0 WHERE id = ?",
                            arguments: [upToSeq, chatId])
        }
        try? await ws.send(.read(chatId: chatId, upToSeq: upToSeq))
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
                    try dbc.execute(sql: "DELETE FROM message WHERE chatId = ? AND (msgId = ? OR id = ?)",
                                    arguments: [chatId, id, id])
                }
            }
        }
        if forAll {
            try? await ws.send(.delete(chatId: chatId, msgIds: msgIds, forAll: true))
        }
    }

    // MARK: - Общие апсерты

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

    static func upsertChatState(_ dbc: GRDB.Database, _ s: ChatStateDTO, ownUserId: String,
                                flags: (pinned: Bool, muted: Bool, archived: Bool)?) throws {
        let me = s.members.first { $0.userId == ownUserId }
        let iAccepted = me?.accepted ?? true
        let isRequest = s.kind == "direct" && !iAccepted
        let peerRead = s.readMarks.filter { $0.key != ownUserId }.values.max() ?? 0
        let peerDelivered = s.deliveredMarks.filter { $0.key != ownUserId }.values.max() ?? 0
        let myRead = s.readMarks[ownUserId] ?? 0
        try dbc.execute(
            sql: """
            INSERT INTO chat (id, kind, title, avatarId, chatDescription, createdBy, createdAt,
                              pinnedMsgId, lastSeq, syncedSeq, myReadUpTo, peerReadUpTo, peerDeliveredUpTo,
                              lastActivityAt, isRequest, iAccepted, pinned, muted, archived, unreadCount)
            VALUES (?,?,?,?,?,?,?,?,?,0,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
              title = excluded.title, avatarId = excluded.avatarId,
              chatDescription = excluded.chatDescription, pinnedMsgId = excluded.pinnedMsgId,
              lastSeq = MAX(chat.lastSeq, excluded.lastSeq),
              myReadUpTo = MAX(chat.myReadUpTo, excluded.myReadUpTo),
              peerReadUpTo = MAX(chat.peerReadUpTo, excluded.peerReadUpTo),
              peerDeliveredUpTo = MAX(chat.peerDeliveredUpTo, excluded.peerDeliveredUpTo),
              isRequest = excluded.isRequest, iAccepted = excluded.iAccepted,
              unreadCount = MAX(0, MAX(chat.lastSeq, excluded.lastSeq) - MAX(chat.myReadUpTo, excluded.myReadUpTo))
            """,
            arguments: [s.chatId, s.kind, s.title, s.avatarId, s.description, s.createdBy,
                        s.createdAt, s.pinnedMsgId, s.lastSeq, myRead, peerRead, peerDelivered,
                        s.createdAt, isRequest, iAccepted,
                        flags?.pinned ?? false, flags?.muted ?? false, flags?.archived ?? false,
                        max(0, s.lastSeq - myRead)])
        if flags != nil {
            try dbc.execute(sql: "UPDATE chat SET pinned = ?, muted = ?, archived = ? WHERE id = ?",
                            arguments: [flags!.pinned, flags!.muted, flags!.archived, s.chatId])
        }
        try dbc.execute(sql: "DELETE FROM member WHERE chatId = ?", arguments: [s.chatId])
        for m in s.members {
            try ChatMemberRow(chatId: s.chatId, userId: m.userId, role: m.role, joinedAt: m.joinedAt).save(dbc)
        }
    }

    static func applyReaction(_ dbc: GRDB.Database, chatId: String, targetMsgId: String,
                              userId: String, emoji: String?) throws {
        guard let row = try Row.fetchOne(
            dbc, sql: "SELECT id, reactions FROM message WHERE chatId = ? AND (msgId = ? OR id = ?)",
            arguments: [chatId, targetMsgId, targetMsgId]) else { return }
        var reactions = (try? JSONDecoder().decode([String: [String]].self,
                                                   from: Data((row["reactions"] as String).utf8))) ?? [:]
        // одна реакция на пользователя: убрать из всех, добавить в новую
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
    }
}
