import CryptoKit
import Foundation
import GRDB
import MsngrCrypto

/// Оркестратор: WS ↔ БД ↔ E2EE. UI никогда не ждёт сеть — читает только БД.
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
    private var outboxWakeup = AsyncStream<Void>.makeStream()
    private var actionWakeup = AsyncStream<Void>.makeStream()
    private var connected = false

    /// typing-события не пишутся в БД — транслируются подписчикам UI
    public nonisolated let typingStream = Broadcast<(chatId: String, userId: String, kind: String?)>()
    /// состояние соединения для UI (сабтайтл «подключение…» вместо стейл-презенса);
    /// подписчик сразу получает текущее состояние
    public nonisolated let connectionStream = Broadcast<Bool>(initial: false)

    /// Новое сообщение, принятое по WS (msg-фрейм, не повтор): для in-app уведомлений.
    public struct IncomingMessage: Sendable {
        public let chatId: String
        public let msgId: String
        public let fromUserId: String
        /// служебный фрейм (skd/edit/reaction/disappearing) — не растит unread
        public let isService: Bool
        /// собственное эхо с другого устройства
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
        // отправки, убитые до ack (state='inflight'), возвращаются в очередь;
        // сервер дедуплицирует возможный повтор по clientMsgId
        try? await db.write { dbc in
            try dbc.execute(sql: "UPDATE outbox SET state = 'ready' WHERE state = 'inflight'")
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
        actionTask?.cancel()
        await ws.stop()
        connected = false
    }

    public var isConnected: Bool { connected }

    /// Приложение ушло в фон: presence offline немедленно, не дожидаясь TTL.
    public func appEnteredBackground() async {
        try? await ws.sendRaw(Data(#"{"t":"bg"}"#.utf8))
    }

    /// Вернулось на экран: presence online + пинок реконнекту и outbox.
    public func appBecameActive() async {
        await ws.nudge()
        try? await ws.sendRaw(Data(#"{"t":"fg"}"#.utf8))
        outboxWakeup.continuation.yield()
    }

    private func handle(_ ev: WSEvent) async {
        switch ev {
        case .connected:
            connected = true
            connectionStream.send(true)
            await sendSyncCursors()
            outboxWakeup.continuation.yield()
            actionWakeup.continuation.yield()
        case .disconnected:
            connected = false
            connectionStream.send(false)
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

    func apply(_ f: WSIncoming) async {
        switch f.t {
        case "msg":
            await applyIncomingMessage(f)
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
                        // строки ещё нет (оригинал ждёт ключа в pendingDecrypt или не пришёл) —
                        // тумбстоун буферизуется и применится при появлении сообщения
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
        let isService = f.service == true
        try? await db.write { dbc in
            if isService {
                // служебный фрейм (skd/reaction/edit): занимает seq, но unread не растит;
                // в полностью прочитанном чате myReadUpTo поглощает seq, чтобы производный
                // unread следующих сообщений не считал служебный фрейм непрочитанным
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
        // recv-ack немедленно, по каждому фрейму (delivered-галочки автору)
        if from != ownUserId {
            try? await ws.send(.recv(chatId: chatId, seqs: [seq]))
        }
        // событие для in-app уведомления — после записи в БД (превью уже читается)
        if !exists, f.body != nil {
            incomingMessageStream.send(IncomingMessage(
                chatId: chatId, msgId: msgId, fromUserId: from,
                isService: isService, isOwn: isOwn))
        }
    }

    /// Причины, при которых расшифровка может удаться позже: групповое сообщение
    /// до sender-key, dr-сообщение раньше своего pk (reorder), либо брошенное
    /// исключение ("exception" — транзиентный сбой, например гонка состояния сессии).
    static let retryableReasons: Set<String> = ["no_sender_key", "no_session", "exception"]

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

    func applyContent(_ content: ContentPayload, chatId: String, msgId: String,
                      seq: Int, from: String, sentAt: Double, ts: Double) async {
        try? await db.write { [ownUserId] dbc in
            switch content.kind {
            case "edit":
                if let target = content.targetMsgId {
                    try dbc.execute(
                        sql: "UPDATE message SET text = ?, edited = 1 WHERE chatId = ? AND (msgId = ? OR id = ?)",
                        arguments: [content.text, chatId, target, target])
                    // оригинала ещё нет (ждёт ключа в pendingDecrypt) —
                    // правка применится при появлении строки
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
                // edit/reaction/deleted, пришедшие раньше этого сообщения, лежат в буфере
                try SyncEngine.applyBuffered(dbc, chatId: chatId, msgId: msgId)
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

    /// Виды контента без собственной строки в ленте; шлются с service-флагом.
    static let serviceKinds: Set<String> = ["edit", "reaction", "disappearing"]

    /// Стабильный clientMsgId skd-конверта: одинаков при ретрае той же раздачи
    /// (дедуп сервера гасит повтор), различен для новой цепочки или новых адресатов.
    static func skdClientMsgId(chatId: String, keyId: String?, skd: Envelope) -> String {
        let recipients = skd.msgs?.keys.sorted().joined(separator: ",") ?? ""
        let digest = SHA256.hash(data: Data(recipients.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        return "skd:\(chatId):\(keyId ?? ""):\(digest)"
    }

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
            let visible = !SyncEngine.serviceKinds.contains(content.kind)
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
                // TOFU: ключ получателя сменился — блокируем до явного принятия,
                // сообщение показываем как failed (баннер в чате предложит принять ключ)
                if let ee = error as? E2EEError, case .identityChanged(let uid) = ee {
                    try? await db.write { dbc in
                        try dbc.execute(sql: "UPDATE outbox SET state = 'blocked' WHERE clientMsgId = ?",
                                        arguments: [item.clientMsgId])
                        try dbc.execute(sql: "UPDATE message SET status = -1 WHERE clientMsgId = ?",
                                        arguments: [item.clientMsgId])
                    }
                    await insertSystemMessage(chatId: item.chatId, text: "identity_changed:\(uid)")
                    continue
                }
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
        var content = try JSONDecoder().decode(ContentPayload.self, from: item.payload)
        // медиа, приложенные офлайн, выгружаются перед шифрованием конверта;
        // ошибка сети здесь — обычный ретрай outbox
        content = try await uploadPendingMedia(content, item: item)
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

        // edit/reaction/disappearing — служебные: сервер не растит ими unread получателей
        let service = Self.serviceKinds.contains(content.kind)
        if info.kind == "direct" {
            let peer = info.members.first { $0 != ownUserId } ?? ownUserId
            let env = try await e2ee.encryptDirect(content: content, toUserId: peer)
            try await ws.send(.send(chatId: item.chatId, clientMsgId: item.clientMsgId,
                                    sentAt: item.createdAt, body: env, service: service))
        } else {
            let (skd, skm) = try await e2ee.encryptGroup(content: content, chatId: item.chatId,
                                                         memberIds: info.members)
            if let skd {
                // clientMsgId детерминирован по (chatId, keyId, адресаты): ретрай той же
                // раздачи гасится серверным дедупом, раздача новым устройствам проходит
                try await ws.send(.send(chatId: item.chatId,
                                        clientMsgId: Self.skdClientMsgId(chatId: item.chatId,
                                                                         keyId: skm.keyId, skd: skd),
                                        sentAt: item.createdAt, body: skd, service: true))
            }
            try await ws.send(.send(chatId: item.chatId, clientMsgId: item.clientMsgId,
                                    sentAt: item.createdAt, body: skm, service: service))
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

    // MARK: - Аплоад локальных медиа перед отправкой

    struct MediaManagerMissing: Error {}

    /// Выгружает медиа с локальными исходниками (mediaId пустой, файл в pendingDir).
    /// После каждого выгруженного элемента обновлённый payload сохраняется в outbox
    /// и в строке сообщения — kill не приводит к повторной выгрузке готовых элементов.
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

    // MARK: - Очередь сервисных действий (read / delete-for-all / accept)

    struct ReadActionPayload: Codable { var upToSeq: Int }
    struct DeleteActionPayload: Codable { var msgIds: [String]; var forAll: Bool }

    /// read-акции схлопываются по чату: одна строка на chatId, побеждает больший upToSeq.
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

    /// Дренаж очереди действий: FIFO, ошибка сети → выход, реконнект разбудит снова.
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
                    try await ws.send(.read(chatId: a.chatId, upToSeq: p.upToSeq))
                case "delete":
                    let p = try JSONDecoder().decode(DeleteActionPayload.self, from: Data(a.payload.utf8))
                    try await ws.send(.delete(chatId: a.chatId, msgIds: p.msgIds, forAll: p.forAll))
                case "accept":
                    try await api.acceptChat(a.chatId)
                default:
                    break // неизвестный тип удаляется ниже
                }
                try? await db.write { [a] dbc in
                    // read мог схлопнуться с бо́льшим upToSeq, пока шла отправка, —
                    // тогда payload изменился и строка остаётся на повторную отправку
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

    // MARK: - Пользовательские действия

    /// Принять новый identity-ключ собеседника и переотправить заблокированные сообщения.
    public func acceptKeyChange(chatId: String, peerUserId: String) async {
        try? e2ee.store.acceptChangedKey(userId: peerUserId)
        try? await db.write { dbc in
            try dbc.execute(sql: """
                UPDATE message SET status = 0 WHERE clientMsgId IN
                (SELECT clientMsgId FROM outbox WHERE chatId = ? AND state = 'blocked')
                """, arguments: [chatId])
            try dbc.execute(sql: "UPDATE outbox SET state = 'ready' WHERE chatId = ? AND state = 'blocked'",
                            arguments: [chatId])
        }
        wakeOutbox()
    }

    public func markRead(chatId: String, upToSeq: Int) async {
        try? await db.write { dbc in
            try dbc.execute(sql: "UPDATE chat SET myReadUpTo = MAX(myReadUpTo, ?), unreadCount = 0 WHERE id = ?",
                            arguments: [upToSeq, chatId])
            try SyncEngine.upsertReadAction(dbc, chatId: chatId, upToSeq: upToSeq)
        }
        actionWakeup.continuation.yield()
    }

    /// Принятие заявки: локально сразу, серверный accept — через очередь действий.
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

    /// Возвращает false, если целевого сообщения нет в БД (реакция не применена).
    @discardableResult
    static func applyReaction(_ dbc: GRDB.Database, chatId: String, targetMsgId: String,
                              userId: String, emoji: String?) throws -> Bool {
        guard let row = try Row.fetchOne(
            dbc, sql: "SELECT id, reactions FROM message WHERE chatId = ? AND (msgId = ? OR id = ?)",
            arguments: [chatId, targetMsgId, targetMsgId]) else { return false }
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
        return true
    }

    // MARK: - Буфер edit/reaction/deleted без оригинала

    static func payloadJSON(_ content: ContentPayload) -> String {
        (try? JSONEncoder().encode(content)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Откладывает edit/reaction/deleted, чьё целевое сообщение ещё не в БД.
    /// Повтор от того же автора замещает строку (последняя правка/реакция побеждает).
    static func bufferPendingApply(_ dbc: GRDB.Database, chatId: String, targetMsgId: String,
                                   kind: String, fromUserId: String, payload: String, seq: Int?) throws {
        try dbc.execute(
            sql: """
            INSERT OR REPLACE INTO pendingApply (chatId, targetMsgId, kind, fromUserId, payload, seq)
            VALUES (?,?,?,?,?,?)
            """,
            arguments: [chatId, targetMsgId, kind, fromUserId, payload, seq])
    }

    /// Применяет отложенные edit/reaction/deleted к только что вставленному сообщению.
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
