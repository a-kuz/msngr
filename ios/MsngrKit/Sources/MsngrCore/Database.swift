import Foundation
import GRDB

/// Why a database this build was handed cannot be opened.
public enum AppDatabaseError: Error {
    /// The file carries migrations this binary does not know: a newer build
    /// wrote it, and its tables no longer mean here what they mean there.
    /// Migrating on top of that, or reading it as if it were ours, is how data
    /// gets corrupted, so the file stays closed and the app says so. There is no
    /// downgrade path (see docs/PROCESS.md): the way out is a newer build, or
    /// starting over on clean storage.
    case schemaFromNewerVersion(applied: [String])
}

public enum AppDatabase {
    /// Opens the database and migrates it. The file itself is protected by the
    /// filesystem (Data Protection); ratchet state is sealed on top of that with the
    /// master key.
    ///
    /// Throws `AppDatabaseError.schemaFromNewerVersion` when the file is ahead
    /// of this build.
    public static func open(at url: URL) throws -> DatabaseQueue {
        var config = Configuration()
        // the app and the notification extension write to one file from separate
        // processes: without waiting on the other's transaction a write fails at once
        config.busyMode = .timeout(5)
        // A write transaction takes its lock at the start rather than upgrading
        // to it halfway: the extension reads a ratchet session and stores the
        // stepped one in the same transaction, and an upgrade that finds
        // another process has committed in between fails outright, where a lock
        // taken up front waits.
        config.defaultTransactionKind = .immediate
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        let dbQueue = try DatabaseQueue(path: url.path, configuration: config)
        let m = migrator
        let ahead = try dbQueue.read { db in try m.unknownMigrations(db) }
        guard ahead.isEmpty else { throw AppDatabaseError.schemaFromNewerVersion(applied: ahead) }
        try m.migrate(dbQueue)
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
                t.column("state", .blob).notNull()   // sealed JSON of DoubleRatchetSession
                t.column("theirIdentityDH", .text).notNull()
                t.primaryKey(["peerUserId", "peerDeviceId"])
            }
            try db.create(table: "senderKeyOut") { t in
                t.column("chatId", .text).primaryKey()
                t.column("state", .blob).notNull()
                // who already has the chain: JSON ["userId/deviceId"]
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
                // TOFU: the first identity key seen; a change raises a warning
                t.column("userId", .text).primaryKey()
                t.column("identitySigning", .text).notNull()
                t.column("verified", .boolean).notNull().defaults(to: false)
                t.column("changedPending", .text) // the new key, awaiting acceptance
            }
            try db.create(table: "kv") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
            // full-text search over message text
            try db.create(virtualTable: "messageFts", using: FTS4()) { t in
                t.synchronize(withTable: "message")
                t.tokenizer = .unicode61()
                t.column("text")
            }
        }
        m.registerMigration("v3-sessionArchive") { db in
            // when both sides initiate at once (glare) there can be several sessions:
            // the active one for sending, plus archived ones that still open incoming
            try db.alter(table: "ratchetSession") { t in
                t.add(column: "archived", .blob)
            }
        }
        m.registerMigration("v2-pendingDecrypt") { db in
            // messages that arrived ahead of their key (a group message before the
            // sender key): kept raw and processed again once the key shows up
            try db.create(table: "pendingDecrypt") { t in
                t.column("chatId", .text).notNull().indexed()
                t.column("msgId", .text).notNull()
                t.column("seq", .integer).notNull()
                t.column("fromUserId", .text).notNull()
                t.column("fromDevice", .text).notNull()
                t.column("sentAt", .double).notNull()
                t.column("ts", .double).notNull()
                t.column("body", .blob).notNull()  // the envelope as JSON
                t.primaryKey(["chatId", "msgId"])
            }
        }
        m.registerMigration("v4-pendingAction") { db in
            // service actions waiting for the network (read receipt, delete-for-all,
            // accepting a request): drained by the worker once connected
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
            // edit, reaction or deletion whose target message is not in the database
            // yet (the original may be waiting for its key in pendingDecrypt):
            // applied once the message row appears
            try db.create(table: "pendingApply") { t in
                t.column("chatId", .text).notNull()
                t.column("targetMsgId", .text).notNull()
                t.column("kind", .text).notNull()    // edit | reaction | deleted
                t.column("fromUserId", .text).notNull()
                t.column("payload", .text).notNull() // ContentPayload as JSON; "{}" for deleted
                t.column("seq", .integer)
                t.primaryKey(["chatId", "targetMsgId", "kind", "fromUserId"])
            }
        }
        m.registerMigration("v6-failReason") { db in
            // why an outgoing message was never sent (codes live in SendFailure), so the
            // UI can state what happened instead of showing "sending" forever
            try db.alter(table: "message") { t in
                t.add(column: "failReason", .text)
            }
        }

        m.registerMigration("v7-mutedUntil") { db in
            // mute with an expiry: the chat stays silent until that moment, then the
            // flag comes off
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
        m.registerMigration("v11-syncCursor") { db in
            // How far the server has replayed this chat's journal to us. Catch-up
            // is pulled portion by portion, and the cursor is stored as each
            // portion is applied, so a run cut off halfway resumes here.
            // Separate from syncedSeq: that one stops at the first seq this
            // device never receives (a message held back by a block, a
            // tombstone), while the catch-up has to move past it.
            try db.alter(table: "chat") { t in
                t.add(column: "syncCursor", .integer).notNull().defaults(to: 0)
            }
        }
        m.registerMigration("v12-badge") { db in
            // The number on the app icon and the position of the count it came
            // from. The app and the extension are separate processes, so the
            // row is what serialises them: a write is a transaction, and a
            // count that lost the race is dropped instead of overwriting a
            // newer one.
            try db.create(table: "badge") { t in
                t.column("id", .integer).primaryKey()
                t.column("value", .integer).notNull().defaults(to: 0)
                t.column("stamp", .integer).notNull().defaults(to: 0)
            }
        }
        m.registerMigration("v13-feedOrderIndexes") { db in
            // The two orderings the app reads a chat by. Both sort on an
            // expression, so without an index on that same expression every
            // read walks the whole chat and sorts it — and the feed is re-read
            // on every commit, which turns a burst of incoming messages into
            // quadratic work.
            try db.execute(sql: """
                CREATE INDEX message_on_chat_feedOrder
                ON message(chatId, COALESCE(seq, 999999999) DESC, sentAt DESC)
                """)
            try db.execute(sql: """
                CREATE INDEX message_on_chat_activity
                ON message(chatId, COALESCE(serverTs, sentAt) DESC)
                """)
        }
        m.registerMigration("v14-chatTombstone") { db in
            // How far a deleted chat's journal was already processed. A direct
            // chat comes back when the peer writes again, and a chat row
            // starting from zero would send the catch-up after every envelope
            // the journal still holds — envelopes whose keys the ratchet has
            // destroyed. The mark seeds the new row's cursors instead.
            try db.create(table: "chatTombstone") { t in
                t.column("chatId", .text).primaryKey()
                t.column("seq", .integer).notNull()
                t.column("deletedAt", .double).notNull()
            }
        }
        m.registerMigration("v15-chatFolder") { db in
            // Tabs above the chat list. A folder keeps its rules and the chats
            // the user placed by hand; the chats themselves stay where they
            // are, so dropping a folder costs nothing but its own rows. Device
            // local for now — see ChatFolders.swift for what a later sync would
            // need.
            try db.create(table: "chatFolder") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("position", .integer).notNull().defaults(to: 0)
                t.column("ruleDirect", .boolean).notNull().defaults(to: false)
                t.column("ruleGroups", .boolean).notNull().defaults(to: false)
                t.column("ruleUnread", .boolean).notNull().defaults(to: false)
                t.column("updatedAt", .double).notNull().defaults(to: 0)
            }
            try db.create(table: "chatFolderChat") { t in
                t.column("folderId", .text).notNull()
                t.column("chatId", .text).notNull()
                t.column("mode", .text).notNull()   // included | excluded
                t.primaryKey(["folderId", "chatId"])
            }
            try db.create(table: "chatFolderPeer") { t in
                t.column("folderId", .text).notNull()
                t.column("userId", .text).notNull()
                t.primaryKey(["folderId", "userId"])
            }
        }
        m.registerMigration("v16-galleryIndexes") { db in
            // The chat's attachments, by kind, in feed order. The gallery reads
            // one kind at a time and pages from the newest down, so the index
            // turns each page into a seek and a short walk; without it every
            // page sorts the whole chat to find the few messages carrying an
            // attachment.
            try db.execute(sql: """
                CREATE INDEX message_on_chat_kindOrder
                ON message(chatId, kind, COALESCE(seq, 999999999) DESC, sentAt DESC)
                """)
        }
        m.registerMigration("v17-actionWithoutChat") { db in
            // Blocking a peer is a queued action too, but it has no chat: blocking
            // also happens from a profile. The column becomes optional.
            try db.create(table: "pendingActionNew") { t in
                t.column("id", .text).primaryKey()
                t.column("type", .text).notNull()
                t.column("chatId", .text)
                t.column("payload", .text).notNull()
                t.column("createdAt", .double).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
            }
            try db.execute(sql: """
                INSERT INTO pendingActionNew (id, type, chatId, payload, createdAt, attempts)
                SELECT id, type, chatId, payload, createdAt, attempts FROM pendingAction
                """)
            try db.drop(table: "pendingAction")
            try db.rename(table: "pendingActionNew", to: "pendingAction")
        }
        return m
    }
}

extension DatabaseMigrator {
    /// Migrations the file has applied that this migrator does not register:
    /// how far the storage is ahead of the binary reading it. Empty for a fresh
    /// file and for one this build can migrate forward.
    func unknownMigrations(_ db: Database) throws -> [String] {
        guard try hasBeenSuperseded(db) else { return [] }
        let known = Set(migrations)
        return try appliedIdentifiers(db).subtracting(known).sorted()
    }
}

// JSON encoding for the composite columns of Message
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
