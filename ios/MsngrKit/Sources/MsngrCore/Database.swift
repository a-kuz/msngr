import Foundation
import GRDB

public enum AppDatabase {
    /// Открывает (и мигрирует) БД. Файл шифруется на уровне FS (Data Protection),
    /// ratchet-состояния дополнительно шифруются ключом из Keychain (см. CryptoStore).
    public static func open(at url: URL) throws -> DatabaseQueue {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        let dbQueue = try DatabaseQueue(path: url.path, configuration: config)
        try migrator.migrate(dbQueue)
        return dbQueue
    }

    public static func openInMemory() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try migrator.migrate(dbQueue)
        return dbQueue
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "user") { t in
                t.column("id", .text).primaryKey()
                t.column("username", .text).notNull()
                t.column("displayName", .text).notNull()
                t.column("bio", .text)
                t.column("avatarId", .text)
                t.column("identityDH", .text)
                t.column("identitySigning", .text)
                t.column("isBlocked", .boolean).notNull().defaults(to: false)
                t.column("online", .boolean).notNull().defaults(to: false)
                t.column("lastSeen", .double).notNull().defaults(to: 0)
            }
            try db.create(table: "chat") { t in
                t.column("id", .text).primaryKey()
                t.column("kind", .text).notNull()
                t.column("title", .text)
                t.column("avatarId", .text)
                t.column("chatDescription", .text)
                t.column("createdBy", .text).notNull()
                t.column("createdAt", .double).notNull()
                t.column("pinnedMsgId", .text)
                t.column("lastSeq", .integer).notNull().defaults(to: 0)
                t.column("syncedSeq", .integer).notNull().defaults(to: 0)
                t.column("unreadCount", .integer).notNull().defaults(to: 0)
                t.column("pinned", .boolean).notNull().defaults(to: false)
                t.column("muted", .boolean).notNull().defaults(to: false)
                t.column("archived", .boolean).notNull().defaults(to: false)
                t.column("draft", .text)
                t.column("myReadUpTo", .integer).notNull().defaults(to: 0)
                t.column("peerReadUpTo", .integer).notNull().defaults(to: 0)
                t.column("peerDeliveredUpTo", .integer).notNull().defaults(to: 0)
                t.column("ttlSeconds", .integer).notNull().defaults(to: 0)
                t.column("lastActivityAt", .double).notNull().defaults(to: 0)
                t.column("isRequest", .boolean).notNull().defaults(to: false)
                t.column("iAccepted", .boolean).notNull().defaults(to: true)
            }
            try db.create(table: "member") { t in
                t.column("chatId", .text).notNull()
                t.column("userId", .text).notNull()
                t.column("role", .text).notNull()
                t.column("joinedAt", .double).notNull()
                t.primaryKey(["chatId", "userId"])
            }
            try db.create(table: "message") { t in
                t.column("id", .text).primaryKey()
                t.column("msgId", .text).unique()
                t.column("chatId", .text).notNull().indexed()
                t.column("seq", .integer)
                t.column("clientMsgId", .text)
                t.column("fromUserId", .text).notNull()
                t.column("sentAt", .double).notNull()
                t.column("serverTs", .double)
                t.column("kind", .text).notNull()
                t.column("text", .text)
                t.column("media", .text)      // JSON
                t.column("album", .text)      // JSON
                t.column("replyTo", .text)    // JSON
                t.column("forward", .text)    // JSON
                t.column("edited", .boolean).notNull().defaults(to: false)
                t.column("deletedForAll", .boolean).notNull().defaults(to: false)
                t.column("status", .integer).notNull()
                t.column("isOutgoing", .boolean).notNull()
                t.column("reactions", .text).notNull().defaults(to: "{}")
                t.column("expiresAt", .double)
            }
            try db.create(indexOn: "message", columns: ["chatId", "seq"])
            try db.create(indexOn: "message", columns: ["chatId", "sentAt"])
            try db.create(table: "outbox") { t in
                t.column("clientMsgId", .text).primaryKey()
                t.column("chatId", .text).notNull()
                t.column("createdAt", .double).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("payload", .blob).notNull()
                t.column("state", .text).notNull().defaults(to: "ready")
            }
            try db.create(table: "ratchetSession") { t in
                t.column("peerUserId", .text).notNull()
                t.column("peerDeviceId", .text).notNull()
                t.column("state", .blob).notNull()   // зашифрованный JSON DoubleRatchetSession
                t.column("theirIdentityDH", .text).notNull()
                t.primaryKey(["peerUserId", "peerDeviceId"])
            }
            try db.create(table: "senderKeyOut") { t in
                t.column("chatId", .text).primaryKey()
                t.column("state", .blob).notNull()
                // кому цепочка уже доставлена: JSON ["userId/deviceId"]
                t.column("distributedTo", .text).notNull().defaults(to: "[]")
            }
            try db.create(table: "senderKeyIn") { t in
                t.column("chatId", .text).notNull()
                t.column("senderUserId", .text).notNull()
                t.column("keyId", .text).notNull()
                t.column("state", .blob).notNull()
                t.primaryKey(["chatId", "senderUserId", "keyId"])
            }
            try db.create(table: "trustedIdentity") { t in
                // TOFU: первый увиденный identity-ключ; смена → предупреждение
                t.column("userId", .text).primaryKey()
                t.column("identitySigning", .text).notNull()
                t.column("verified", .boolean).notNull().defaults(to: false)
                t.column("changedPending", .text) // новый ключ, ждущий подтверждения
            }
            try db.create(table: "kv") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
            // FTS-поиск по тексту сообщений
            try db.create(virtualTable: "messageFts", using: FTS4()) { t in
                t.synchronize(withTable: "message")
                t.tokenizer = .unicode61()
                t.column("text")
            }
        }
        m.registerMigration("v3-sessionArchive") { db in
            // при одновременной инициации (glare) сессий может быть несколько:
            // активная для отправки + архивные, которыми ещё расшифровываются входящие
            try db.alter(table: "ratchetSession") { t in
                t.add(column: "archived", .blob)
            }
        }
        m.registerMigration("v2-pendingDecrypt") { db in
            // сообщения, пришедшие раньше своего ключа (напр. групповое до sender-key):
            // хранятся сырыми и переобрабатываются, когда ключ приходит
            try db.create(table: "pendingDecrypt") { t in
                t.column("chatId", .text).notNull().indexed()
                t.column("msgId", .text).notNull()
                t.column("seq", .integer).notNull()
                t.column("fromUserId", .text).notNull()
                t.column("fromDevice", .text).notNull()
                t.column("sentAt", .double).notNull()
                t.column("ts", .double).notNull()
                t.column("body", .blob).notNull()  // JSON-конверт
                t.primaryKey(["chatId", "msgId"])
            }
        }
        m.registerMigration("v4-pendingAction") { db in
            // сервисные действия (read receipt, delete-for-all, accept заявки),
            // ждущие сети: дренятся воркером при connected
            try db.create(table: "pendingAction") { t in
                t.column("id", .text).primaryKey()
                t.column("type", .text).notNull()
                t.column("chatId", .text).notNull()
                t.column("payload", .text).notNull()
                t.column("createdAt", .double).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
            }
        }
        m.registerMigration("v5-pendingApply") { db in
            // edit/reaction/deleted, чьё целевое сообщение ещё не в БД
            // (например, оригинал ждёт ключа в pendingDecrypt):
            // применяются, когда строка сообщения появляется
            try db.create(table: "pendingApply") { t in
                t.column("chatId", .text).notNull()
                t.column("targetMsgId", .text).notNull()
                t.column("kind", .text).notNull()    // edit | reaction | deleted
                t.column("fromUserId", .text).notNull()
                t.column("payload", .text).notNull() // JSON ContentPayload; для deleted — "{}"
                t.column("seq", .integer)
                t.primaryKey(["chatId", "targetMsgId", "kind", "fromUserId"])
            }
        }
        m.registerMigration("v6-failReason") { db in
            // причина, по которой исходящее осталось неотправленным (коды в SendFailure):
            // UI объясняет отказ вместо вечного «отправляется»
            try db.alter(table: "message") { t in
                t.add(column: "failReason", .text)
            }
        }

        m.registerMigration("v7-mutedUntil") { db in
            // mute со сроком: до этого момента чат молчит, дальше флаг снимается
            try db.alter(table: "chat") { t in
                t.add(column: "mutedUntil", .double)
            }
        }

        m.registerMigration("v8-historyGap") { db in
            // A seq this device cannot read: the envelope was fetched but stays
            // undecryptable. Kept with the failure reason and an attempt counter
            // so repair can ask the sender again; upward pagination treats the
            // record as closed and stops re-requesting the range from the server.
            try db.create(table: "historyGap") { t in
                t.column("chatId", .text).notNull().indexed()
                t.column("seq", .integer).notNull()
                t.column("msgId", .text)
                t.column("fromUserId", .text)
                t.column("sentAt", .double)
                t.column("reason", .text).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 1)
                t.column("lastTriedAt", .double).notNull()
                t.primaryKey(["chatId", "seq"])
            }
        }

        m.registerMigration("v9-repair") { db in
            // Every envelope this device could not read is kept: it is the only
            // local copy, and a replay after the session is fixed has nothing to
            // work from otherwise. The counters drive the sweep — how often a row
            // is retried, when the sender is asked for a fresh copy, and when the
            // envelope has outlived any use.
            try db.alter(table: "pendingDecrypt") { t in
                t.add(column: "reason", .text)
                t.add(column: "attempts", .integer).notNull().defaults(to: 0)
                t.add(column: "firstSeenAt", .double).notNull().defaults(to: 0)
                t.add(column: "lastTriedAt", .double).notNull().defaults(to: 0)
                t.add(column: "repairAttempts", .integer).notNull().defaults(to: 0)
                t.add(column: "repairAskedAt", .double).notNull().defaults(to: 0)
            }
            // Sender key distribution is confirmed by the recipient. Until the
            // confirmation arrives the address stays in `attemptedAt` and the
            // chain is handed out again once the wait is over.
            try db.alter(table: "senderKeyOut") { t in
                t.add(column: "attemptedAt", .text).notNull().defaults(to: "{}")
            }
        }

        m.registerMigration("v10-notificationShown") { db in
            // One message gets one banner. The row is the claim on it: the
            // extension and the app both write it before presenting, and the
            // insert that wins is the one that presents. Two handlers running
            // at once, or a push arriving after the app already showed the
            // message, therefore cannot produce a second banner.
            try db.create(table: "notificationShown") { t in
                t.column("msgId", .text).primaryKey()
                t.column("chatId", .text).notNull()
                t.column("seq", .integer).notNull().defaults(to: 0)
                t.column("shownAt", .double).notNull().indexed()
            }
        }
        return m
    }
}

// JSON-кодирование сложных колонок Message
extension Message {
    public init(row: Row) throws {
        let dec = JSONDecoder()
        id = row["id"]
        msgId = row["msgId"]
        chatId = row["chatId"]
        seq = row["seq"]
        clientMsgId = row["clientMsgId"]
        fromUserId = row["fromUserId"]
        sentAt = row["sentAt"]
        serverTs = row["serverTs"]
        kind = MessageKind(rawValue: row["kind"]) ?? .text
        text = row["text"]
        media = (row["media"] as String?).flatMap { try? dec.decode(MediaInfo.self, from: Data($0.utf8)) }
        album = (row["album"] as String?).flatMap { try? dec.decode([MediaInfo].self, from: Data($0.utf8)) }
        replyTo = (row["replyTo"] as String?).flatMap { try? dec.decode(ReplyPreview.self, from: Data($0.utf8)) }
        forward = (row["forward"] as String?).flatMap { try? dec.decode(ForwardInfo.self, from: Data($0.utf8)) }
        edited = row["edited"]
        deletedForAll = row["deletedForAll"]
        status = MessageStatus(rawValue: row["status"]) ?? .sent
        isOutgoing = row["isOutgoing"]
        reactions = (row["reactions"] as String?).flatMap { try? dec.decode([String: [String]].self, from: Data($0.utf8)) } ?? [:]
        expiresAt = row["expiresAt"]
        failReason = row["failReason"]
    }

    public func encode(to container: inout PersistenceContainer) throws {
        let enc = JSONEncoder()
        func js<T: Encodable>(_ v: T?) -> String? {
            guard let v, let d = try? enc.encode(v) else { return nil }
            return String(data: d, encoding: .utf8)
        }
        container["id"] = id
        container["msgId"] = msgId
        container["chatId"] = chatId
        container["seq"] = seq
        container["clientMsgId"] = clientMsgId
        container["fromUserId"] = fromUserId
        container["sentAt"] = sentAt
        container["serverTs"] = serverTs
        container["kind"] = kind.rawValue
        container["text"] = text
        container["media"] = js(media)
        container["album"] = js(album)
        container["replyTo"] = js(replyTo)
        container["forward"] = js(forward)
        container["edited"] = edited
        container["deletedForAll"] = deletedForAll
        container["status"] = status.rawValue
        container["isOutgoing"] = isOutgoing
        container["reactions"] = js(reactions) ?? "{}"
        container["expiresAt"] = expiresAt
        container["failReason"] = failReason
    }
}
