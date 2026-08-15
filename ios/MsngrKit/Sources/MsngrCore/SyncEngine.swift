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
    /// периодические фоновые проходы: снятие истёкшего mute и очередь нечитаемых
    private var maintenanceTask: Task<Void, Never>?
    private var outboxWakeup = AsyncStream<Void>.makeStream()
    private var actionWakeup = AsyncStream<Void>.makeStream()
    private var connected = false

    /// typing-события не пишутся в БД — транслируются подписчикам UI
    public nonisolated let typingStream = Broadcast<(chatId: String, userId: String, kind: String?)>()
    /// состояние соединения для UI (сабтайтл «подключение…» вместо стейл-презенса);
    /// подписчик сразу получает текущее состояние
    public nonisolated let connectionStream = Broadcast<Bool>(initial: false)
    /// устройство отключено от аккаунта (токен отозван): переподключений больше
    /// не будет, приложению остаётся увести пользователя на регистрацию
    public nonisolated let sessionRevokedStream = Broadcast<Void>()

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
        Task { await self.refreshBlocked() }
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sweepExpiredMutes()
                // очередь нечитаемых переигрывается и при старте, и дальше по
                // кругу: запись, ждущая ключа, иначе ждала бы следующего
                // удачного фрейма в том же чате — то есть могла не дождаться
                await self?.sweepUnreadable()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
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
        maintenanceTask?.cancel()
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
        await sweepExpiredMutes()
    }

    /// Снимает mute у чатов, чей срок вышел: локально и на сервере.
    /// Сервер считает истёкший mute снятым сам, но без явного снятия флаг
    /// вернулся бы в клиент со следующим снапшотом.
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

    /// Список заблокированных с сервера в локальный флаг user.isBlocked.
    public func refreshBlocked() async {
        guard let ids = try? await api.blockedUsers() else { return }
        try? await db.write { dbc in
            try dbc.execute(sql: "UPDATE user SET isBlocked = 0 WHERE isBlocked = 1")
            for id in ids {
                try dbc.execute(sql: "UPDATE user SET isBlocked = 1 WHERE id = ?", arguments: [id])
            }
        }
    }

    /// Блокировка собеседника: сервер + локальный флаг, который гасит инпут-бар.
    public func setBlocked(userId: String, blocked: Bool) async throws {
        try await api.setBlocked(userId, blocked: blocked)
        try await db.write { dbc in
            try dbc.execute(sql: "UPDATE user SET isBlocked = ? WHERE id = ?",
                            arguments: [blocked, userId])
        }
    }

    private func handle(_ ev: WSEvent) async {
        switch ev {
        case .connected:
            connected = true
            connectionStream.send(true)
            await sendSyncCursors()
            outboxWakeup.continuation.yield()
            actionWakeup.continuation.yield()
            // связь вернулась: ключи, которых не хватало, могли доехать, а
            // запросы отправителю — уйти
            Task { await self.sweepUnreadable() }
        case .disconnected:
            connected = false
            connectionStream.send(false)
            // порция оборвалась: следующее подключение начнёт догон
            // с подтверждённых курсоров в БД
            catchupPending = []
            catchupSent = [:]
        case .unauthorized:
            connected = false
            connectionStream.send(false)
            sessionRevokedStream.send(())
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
                try SyncEngine.upsertChatState(
                    dbc, entry.state, ownUserId: ownUserId,
                    flags: ChatFlags(pinned: entry.flags.pinned, muted: entry.flags.muted,
                                     mutedUntil: entry.flags.mutedUntil, archived: entry.flags.archived))
            }
        }
    }

    /// Чаты, у которых после последней порции осталась история дальше курсора.
    private var catchupPending: Set<String> = []
    /// Курсоры последней запрошенной порции: следующая уходит только с новыми,
    /// иначе догон крутил бы порции, не двигаясь с места.
    private var catchupSent: [String: Int] = [:]

    /// Начало догона: весь известный клиенту мир с подтверждённых границ.
    private func sendSyncCursors() async {
        guard connected else { return }
        let cursors = (try? await db.read { dbc in
            try HistoryWindow.catchupCursors(dbc)
        }) ?? [:]
        catchupPending = []
        catchupSent = cursors
        try? await ws.send(.sync(cursors: cursors))
    }

    /// Прогресс догона одного чата. Курсор подтверждается уже после того, как
    /// порция применена (фреймы порции идут до `syncState`), поэтому обрыв
    /// посреди догона стоит клиенту одной порции, а не всей истории.
    private func applySyncState(_ f: WSIncoming) async {
        guard let chatId = f.chatId, let cursor = f.cursor else { return }
        try? await db.write { dbc in
            try dbc.execute(sql: "UPDATE chat SET syncCursor = MAX(syncCursor, ?) WHERE id = ?",
                            arguments: [cursor, chatId])
        }
        if f.more == true { catchupPending.insert(chatId) } else { catchupPending.remove(chatId) }
    }

    /// Конец порции: пока сервер сообщает, что доигрывать есть что, клиент
    /// просит следующую — с курсоров, подтверждённых в базе. Между порциями
    /// объект сессии свободен для живого трафика, поэтому цикл догона крутится
    /// фреймами, а не одним запросом.
    private func finishCatchupPortion(more: Bool) async {
        guard more, connected else { return }
        let pending = catchupPending
        let cursors = (try? await db.read { dbc -> [String: Int] in
            let behind = try HistoryWindow.catchupCursors(dbc)
                .filter { pending.contains($0.key) }
            // порция кончилась раньше, чем дошла до отставших: спрашиваем те
            // чаты, чей журнал заведомо длиннее курсора
            return behind.isEmpty ? try HistoryWindow.catchupCursors(dbc, behindOnly: true) : behind
        }) ?? [:]
        guard !cursors.isEmpty, cursors != catchupSent else { return }
        catchupSent = cursors
        try? await ws.send(.catchup(cursors: cursors))
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
                // chat-фрейм несёт только userId участников — профили новых
                // пользователей дотягиваются, иначе UI показывает «…» до рестарта
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
    /// userId, по которым запрос профиля уже в полёте (защита от шторма
    /// одинаковых запросов при пачке фреймов от одного нового пользователя)
    private var userFetchesInFlight: Set<String> = []

    /// Дотягивает с сервера профили пользователей, которых нет в таблице user.
    private func fetchMissingUsers(_ ids: [String]) async {
        let missing: [String] = (try? await db.read { dbc in
            try ids.filter { id in
                try !Bool.fetchOne(dbc, sql: "SELECT EXISTS(SELECT 1 FROM user WHERE id = ?)",
                                   arguments: [id])!
            }
        }) ?? []
        for id in missing where !userFetchesInFlight.contains(id) {
            userFetchesInFlight.insert(id)
            // сеть — вне пути применения фрейма: сообщение не ждёт профиль
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
        // сообщение от пользователя без профиля в БД (свежий участник) —
        // дотянуть, чтобы имя отправителя отобразилось сразу
        await fetchMissingUsers([from])

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
            if case .undecryptable(let reason) = result {
                await recordUnreadable(reason: reason, chatId: chatId, msgId: msgId, seq: seq,
                                       from: from, fromDevice: fromDevice,
                                       sentAt: f.sentAt ?? 0, ts: f.ts ?? 0, body: body)
            } else {
                await storeIncoming(result, chatId: chatId, msgId: msgId, seq: seq, from: from,
                                    fromDevice: fromDevice, sentAt: f.sentAt ?? 0, ts: f.ts ?? 0)
                // получили контент/ключ → пробуем переиграть отложенные этого чата
                await retryPending(chatId: chatId)
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
        // recv-ack немедленно, по каждому фрейму (delivered-галочки автору);
        // по заявке до принятия не шлём: получатель невидим автору
        let isRequestChat = (try? await db.read { dbc in
            try Bool.fetchOne(dbc, sql: "SELECT isRequest FROM chat WHERE id = ?", arguments: [chatId]) ?? false
        }) ?? false
        if from != ownUserId, !isRequestChat {
            try? await ws.send(.recv(chatId: chatId, seqs: [seq]))
        }
        // событие для in-app уведомления — после записи в БД (превью уже читается)
        if !exists, f.body != nil {
            incomingMessageStream.send(IncomingMessage(
                chatId: chatId, msgId: msgId, fromUserId: from,
                isService: isService, isOwn: isOwn))
        }
    }

    // MARK: - Нечитаемые сообщения

    /// Конверт, который устройство прочитать не смогло, вместе со счётчиками
    /// его обработки.
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

    /// Нечитаемый конверт: сохраняем и записываем его seq.
    ///
    /// Конверт хранится при любой причине — локальная база единственная копия,
    /// и после починки сессии повторять было бы нечего. Запись seq выводит отказ
    /// из молчания: пагинация перестаёт дёргать сервер за этот диапазон, а лента
    /// знает, что сообщение потеряно, а не отсутствует.
    private func recordUnreadable(reason rawReason: String, chatId: String, msgId: String, seq: Int,
                                  from: String, fromDevice: String, sentAt: Double,
                                  ts: Double, body: JSONValue) async {
        guard rawReason != "own_echo" else { return }
        let reason: String
        if rawReason == "not_addressed" {
            // в direct отправитель адресует все устройства обеих сторон, поэтому
            // отсутствие своего бокса — дефект и чинится; в группе адресные
            // фреймы (раздача цепочки, ремонт) идут одному участнику по замыслу
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
            try dbc.execute(
                sql: """
                INSERT INTO pendingDecrypt (chatId, msgId, seq, fromUserId, fromDevice, sentAt, ts,
                                            body, reason, attempts, firstSeenAt, lastTriedAt)
                VALUES (?,?,?,?,?,?,?,?,?,1,?,?)
                ON CONFLICT(chatId, msgId) DO UPDATE SET
                  reason = excluded.reason, attempts = pendingDecrypt.attempts + 1,
                  lastTriedAt = excluded.lastTriedAt
                """,
                arguments: [chatId, msgId, seq, from, fromDevice, sentAt, ts, data, reason, now, now])
            try HistoryWindow.recordGap(dbc, chatId: chatId, seq: seq, reason: reason,
                                        msgId: msgId, fromUserId: from, sentAt: sentAt, now: now)
            return try Int.fetchOne(dbc, sql: "SELECT attempts FROM pendingDecrypt WHERE chatId = ? AND msgId = ?",
                                    arguments: [chatId, msgId]) ?? 1
        }) ?? 1
        MsngrLog.repair.error(
            "unreadable chat=\(chatId, privacy: .public) seq=\(seq, privacy: .public) reason=\(reason, privacy: .public) attempts=\(attempts, privacy: .public)")
        // неустранимая причина сама не пройдёт — просим копию у отправителя сразу
        guard !MessageRepair.retryableReasons.contains(reason) else { return }
        let pending = PendingEnvelope(chatId: chatId, msgId: msgId, seq: seq, from: from,
                                      fromDevice: fromDevice, sentAt: sentAt, ts: ts, body: data,
                                      reason: reason, attempts: attempts, firstSeenAt: now,
                                      lastTriedAt: now, repairAttempts: 0, repairAskedAt: 0)
        await requestRepairIfDue(pending, now: now)
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

    /// Переигрывает отложенные конверты чата немедленно: ключ, который только что
    /// приехал, открывает всё, что его ждало, поэтому пауза здесь не нужна.
    /// Раздача sender key разблокирует ещё сообщения, поэтому проход повторяется,
    /// пока есть прогресс.
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

    /// Проход по всем отложенным конвертам: переиграть то, что могло открыться,
    /// попросить копию того, что не откроется, забыть отжившее. Идёт при старте
    /// движка, при реконнекте и по кругу в фоне.
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

    /// Одна попытка расшифровать сохранённый конверт. Успех уносит его в ленту и
    /// закрывает запись о пропаже, неудача считается попыткой.
    private func replay(_ pending: PendingEnvelope) async -> Bool {
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
        // seq закрыт: строкой ленты — тогда запись о пропаже не нужна вовсе,
        // иначе молчаливой причиной, чтобы пагинация не пошла за ним снова
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

    /// Молчаливая причина для seq, который обработан, но своей строки в ленте не
    /// получает; nil — строка есть, запись о пропаже больше не нужна.
    private static func settledReason(_ result: DecryptedIncoming) -> String? {
        switch result {
        case .senderKeyDistribution: return "sender_key"
        case .identityChanged(_, .none): return "identity_changed"
        case .content(let content), .identityChanged(_, .some(let content)):
            return serviceKinds.contains(content.kind) ? "service" : nil
        case .undecryptable(let reason): return reason
        }
    }

    /// Конверт отжил своё: сессии, которой он шифровался, давно нет, и попытки
    /// ремонта потрачены. Запись о пропавшем seq остаётся.
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

    /// Просит у отправителя свежую копию сообщения, если по счётчику и паузе
    /// пора. Пользователя это не касается: запрос уходит сам.
    private func requestRepairIfDue(_ pending: PendingEnvelope, now: Double) async {
        guard MessageRepair.repairDue(reason: pending.reason, firstSeenAt: pending.firstSeenAt,
                                      repairAttempts: pending.repairAttempts,
                                      repairAskedAt: pending.repairAskedAt, now: now) else { return }
        // заявка до принятия: автор не должен узнать, что на той стороне
        // кто-то есть, — конверт ждёт принятия, следующий проход попросит копию
        let isRequest = (try? await db.read { dbc in
            try Bool.fetchOne(dbc, sql: "SELECT isRequest FROM chat WHERE id = ?",
                              arguments: [pending.chatId]) ?? false
        }) ?? false
        guard !isRequest else { return }
        let attempt = pending.repairAttempts + 1
        // сессия не открыла его конверт — запрос уехал бы в неё же; помечаем её
        // на пересборку, тогда запрос уйдёт свежим X3DH и ответ придёт в новую
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
            // попытка считается и для ленты: нейтральная заглушка появляется,
            // только когда чинить уже пробовали
            try HistoryWindow.recordGap(dbc, chatId: pending.chatId, seq: pending.seq,
                                        reason: pending.reason ?? "unknown",
                                        msgId: pending.msgId, fromUserId: pending.from,
                                        sentAt: pending.sentAt, now: now)
        }
        MsngrLog.repair.notice(
            "repair asked chat=\(pending.chatId, privacy: .public) seq=\(pending.seq, privacy: .public) reason=\(pending.reason ?? "unknown", privacy: .public) attempt=\(attempt, privacy: .public)")
    }

    // MARK: - Ремонт через отправителя

    /// Виды контента протокола ремонта: адресный запрос копии, копия и
    /// подтверждение раздачи sender key. Своей строки в ленте не имеют.
    static let repairKinds: Set<String> = ["repairRequest", "repair", "skdAck"]

    /// Обрабатывает контент протокола ремонта; false — обычный контент.
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

    /// Собеседник не смог прочитать наше сообщение: перешифровываем его текущей
    /// сессией и отправляем ему заново. Копия несёт исходный msgId, поэтому в
    /// его ленте она встаёт на место пропавшего сообщения, а не рядом с ним.
    private func answerRepairRequest(_ request: ContentPayload, chatId: String, from: String) async {
        guard let target = request.targetMsgId, from != ownUserId else { return }
        // группа: цепочка ему не доехала — раздача забывается, следующее
        // сообщение в чат раздаст её заново
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
        // просить копию можно только того, что и так было адресовано просящему:
        // вступивший позже участник иначе получил бы историю, закрытую для него
        // сменой цепочки
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

    /// Копия от отправителя: встаёт под исходным msgId и seq, поэтому дубля в
    /// ленте не появляется, и закрывает запись о пропаже.
    private func applyRepair(_ repair: ContentPayload, chatId: String, from: String) async {
        guard let target = repair.repairOf, let json = repair.orig,
              let original = try? JSONDecoder().decode(ContentPayload.self, from: Data(json.utf8)),
              let seq = repair.repairSeq, seq > 0 else { return }
        // копию принимаем только от автора пропавшего сообщения и только на то,
        // о пропаже чего у нас есть запись: иначе участник чата мог бы записать
        // свой текст под чужим msgId
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

    /// Подтверждение раздачи sender key её отправителю: без него он не узнает,
    /// что цепочка доехала, и будет раздавать её снова.
    private func confirmSenderKeyDistribution(chatId: String, keyId: String, to userId: String) async {
        var ack = ContentPayload(kind: "skdAck")
        ack.to = userId
        ack.keyId = keyId
        // круг подтверждения совпадает с кругом раздачи: повтор той же раздачи
        // получает новое подтверждение, а не гасится дедупом сервера
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

    /// Применяет сообщение из серверной истории (пагинация вверх).
    /// Обычный контент апсертится строкой ленты; edit/reaction применяются
    /// к оригиналу, а если его ещё нет — буферизуются в pendingApply
    /// (в истории событие может идти раньше своей цели по порядку реплея).
    /// lastActivityAt не трогается: история старше текущей активности чата.
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
                break // текущий TTL чата уже в chat-state, историческая смена не переигрывается
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
            try dbc.execute(
                sql: """
                UPDATE message SET msgId = ?, seq = ?, serverTs = ?, status = MAX(status, 1),
                  failReason = NULL
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

    /// Отказ сервера по нашему фрейму. Отправка помечается неотправленной с кодом
    /// причины и уходит из outbox: то, что сервер отверг, повторять бессмысленно —
    /// иначе сообщение навсегда остаётся в состоянии «отправляется».
    private func applyServerError(_ f: WSIncoming) async {
        guard let clientMsgId = f.clientMsgId else { return }
        let reason = f.error ?? SendFailure.sendFailed
        try? await db.write { dbc in
            try dbc.execute(sql: "DELETE FROM outbox WHERE clientMsgId = ?", arguments: [clientMsgId])
            try dbc.execute(
                sql: "UPDATE message SET status = ?, failReason = ? WHERE clientMsgId = ?",
                arguments: [MessageStatus.failed.rawValue, reason, clientMsgId])
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
    static let serviceKinds: Set<String> = Set(["edit", "reaction", "disappearing"])
        .union(SyncEngine.repairKinds)

    /// Единственная точка отправки: пишет в БД + outbox, будит воркер. Работает офлайн.
    /// clientMsgId задаётся явно там, где повтор должен схлопнуться серверным
    /// дедупом (запрос копии, ответ на него, подтверждение раздачи цепочки).
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
                        try dbc.execute(
                            sql: "UPDATE message SET status = -1, failReason = ? WHERE clientMsgId = ?",
                            arguments: [SendFailure.identityChanged, item.clientMsgId])
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
                        try dbc.execute(
                            sql: "UPDATE message SET status = -1, failReason = ? WHERE clientMsgId = ?",
                            arguments: [SendFailure.tooManyAttempts, item.clientMsgId])
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

        // edit/reaction/disappearing и протокол ремонта — служебные: сервер не
        // растит ими unread получателей
        let service = Self.serviceKinds.contains(content.kind)
        if let addressee = content.to {
            // адресный фрейм (запрос копии, копия, подтверждение цепочки): он
            // касается двух устройств, поэтому едет pairwise и в группе тоже
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
                UPDATE message SET status = 0, failReason = NULL WHERE clientMsgId IN
                (SELECT clientMsgId FROM outbox WHERE chatId = ? AND state = 'blocked')
                """, arguments: [chatId])
            try dbc.execute(sql: "UPDATE outbox SET state = 'ready' WHERE chatId = ? AND state = 'blocked'",
                            arguments: [chatId])
        }
        wakeOutbox()
    }

    /// Заявку до принятия не отмечаем прочитанной: автор не должен узнать,
    /// что получатель открывал чат (сервер такую марку тоже отбрасывает).
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

    /// Локальные флаги чата из снапшота сервера.
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
              -- принятие необратимо: локальный accept не откатывается снапшотом,
              -- который сервер собрал до доставки нашего /accept
              isRequest = MIN(chat.isRequest, excluded.isRequest),
              iAccepted = MAX(chat.iAccepted, excluded.iAccepted),
              unreadCount = MAX(0, MAX(chat.lastSeq, excluded.lastSeq) - MAX(chat.myReadUpTo, excluded.myReadUpTo))
            """,
            arguments: [s.chatId, s.kind, s.title, s.avatarId, s.description, s.createdBy,
                        s.createdAt, s.pinnedMsgId, s.lastSeq, myRead, peerRead, peerDelivered,
                        s.createdAt, isRequest, iAccepted,
                        flags?.pinned ?? false, flags?.muted ?? false, flags?.archived ?? false,
                        max(0, s.lastSeq - myRead)])
        if let flags {
            try dbc.execute(
                sql: "UPDATE chat SET pinned = ?, muted = ?, mutedUntil = ?, archived = ? WHERE id = ?",
                arguments: [flags.pinned, flags.muted, flags.mutedUntil, flags.archived, s.chatId])
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
