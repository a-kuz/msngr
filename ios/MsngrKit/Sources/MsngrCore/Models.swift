import Foundation
import GRDB

public struct User: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "user"
    public var id: String
    public var username: String
    public var displayName: String
    public var bio: String?
    public var avatarId: String?
    public var identityDH: String?      // b64url X25519 pub
    public var identitySigning: String? // b64url Ed25519 pub
    public var isBlocked: Bool = false
    public var online: Bool = false
    public var lastSeen: Double = 0

    public init(id: String, username: String, displayName: String,
                bio: String? = nil, avatarId: String? = nil) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.bio = bio
        self.avatarId = avatarId
    }
}

public enum ChatKind: String, Codable { case direct, group }

public struct Chat: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "chat"
    public var id: String
    public var kind: ChatKind
    public var title: String?
    public var avatarId: String?
    public var chatDescription: String?
    public var createdBy: String
    public var createdAt: Double
    public var pinnedMsgId: String?
    /// последний seq на сервере (из state) и последний локально применённый
    public var lastSeq: Int
    public var syncedSeq: Int
    // локальные атрибуты
    public var unreadCount: Int = 0
    public var pinned: Bool = false
    public var muted: Bool = false
    /// момент снятия mute; nil при muted — бессрочно
    public var mutedUntil: Double?
    public var archived: Bool = false
    public var draft: String?
    public var myReadUpTo: Int = 0
    public var peerReadUpTo: Int = 0       // max по остальным участникам
    public var peerDeliveredUpTo: Int = 0
    public var ttlSeconds: Int = 0          // disappearing messages
    /// message request: чат в «Заявках» (для получателя, пока не принял)
    public var isRequest: Bool = false
    /// принял ли я этот чат (для direct-получателя)
    public var iAccepted: Bool = true
    /// сортировка чат-листа
    public var lastActivityAt: Double

    public init(id: String, kind: ChatKind, title: String?, createdBy: String,
                createdAt: Double, lastSeq: Int = 0, syncedSeq: Int = 0,
                lastActivityAt: Double = 0) {
        self.id = id
        self.kind = kind
        self.title = title
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.lastSeq = lastSeq
        self.syncedSeq = syncedSeq
        self.lastActivityAt = lastActivityAt
    }
}

public struct ChatMemberRow: Codable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "member"
    public var chatId: String
    public var userId: String
    public var role: String
    public var joinedAt: Double

    public init(chatId: String, userId: String, role: String, joinedAt: Double) {
        self.chatId = chatId
        self.userId = userId
        self.role = role
        self.joinedAt = joinedAt
    }
}

public enum MessageStatus: Int, Codable, Comparable {
    case failed = -1
    case sending = 0
    case sent = 1
    case delivered = 2
    case read = 3
    public static func < (a: MessageStatus, b: MessageStatus) -> Bool { a.rawValue < b.rawValue }
}

public enum MessageKind: String, Codable {
    case text, photo, video, file, voice, album, contact, system
}

public struct MediaInfo: Codable, Equatable {
    public var type: String        // photo|video|file|voice
    public var mediaId: String
    public var key: String         // b64 ключ
    public var hash: String        // b64 sha256 ciphertext
    public var size: Int
    public var mime: String
    public var name: String?
    public var w: Int?
    public var h: Int?
    public var dur: Double?
    public var waveform: [Int]?    // 0..31, до 100 бакетов
    public var blurhash: String?
    public var thumbMediaId: String?  // превью-кадр видео (отдельный блоб)
    public var thumbKey: String?
    public var thumbHash: String?
    /// имя локального файла в MediaManager.pendingDir, пока медиа не выгружено
    /// (mediaId пустой); outbox-воркер выгружает и заполняет mediaId/key/hash
    public var localPath: String?
    public var thumbLocalPath: String?

    public init(type: String, mediaId: String, key: String, hash: String, size: Int, mime: String) {
        self.type = type
        self.mediaId = mediaId
        self.key = key
        self.hash = hash
        self.size = size
        self.mime = mime
    }
}

public struct ReplyPreview: Codable, Equatable {
    public var msgId: String
    public var authorId: String
    public var text: String     // короткое превью
    public var kind: String

    public init(msgId: String, authorId: String, text: String, kind: String) {
        self.msgId = msgId
        self.authorId = authorId
        self.text = text
        self.kind = kind
    }
}

public struct ForwardInfo: Codable, Equatable {
    public var fromUserId: String
    public var fromName: String
    public init(fromUserId: String, fromName: String) {
        self.fromUserId = fromUserId
        self.fromName = fromName
    }
}

public struct Message: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "message"
    /// локальный id = clientMsgId для своих, msgId для чужих
    public var id: String
    public var msgId: String?          // серверный id (null до ack)
    public var chatId: String
    public var seq: Int?               // null до ack
    public var clientMsgId: String?
    public var fromUserId: String
    public var sentAt: Double
    public var serverTs: Double?
    public var kind: MessageKind
    public var text: String?
    public var media: MediaInfo?
    public var album: [MediaInfo]?
    public var replyTo: ReplyPreview?
    public var forward: ForwardInfo?
    public var edited: Bool = false
    public var deletedForAll: Bool = false
    public var status: MessageStatus
    public var isOutgoing: Bool
    /// reactions: emoji -> [userId]
    public var reactions: [String: [String]] = [:]
    public var expiresAt: Double?      // disappearing
    /// причина отказа при status == .failed (коды в SendFailure)
    public var failReason: String?

    public init(id: String, chatId: String, fromUserId: String, sentAt: Double,
                kind: MessageKind, text: String?, status: MessageStatus, isOutgoing: Bool) {
        self.id = id
        self.chatId = chatId
        self.fromUserId = fromUserId
        self.sentAt = sentAt
        self.kind = kind
        self.text = text
        self.status = status
        self.isOutgoing = isOutgoing
    }

    // JSON-колонки
    enum CodingKeys: String, CodingKey {
        case id, msgId, chatId, seq, clientMsgId, fromUserId, sentAt, serverTs,
             kind, text, media, album, replyTo, forward, edited, deletedForAll,
             status, isOutgoing, reactions, expiresAt, failReason
    }
}

public struct OutboxItem: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "outbox"
    public var clientMsgId: String
    public var chatId: String
    public var createdAt: Double
    public var attempts: Int = 0
    /// plaintext-контент (JSON ContentPayload) — шифруется при отправке
    public var payload: Data
    /// ready (ждёт отправки) | inflight (отправлено, ждёт ack)
    public var state: String = "ready"

    public init(clientMsgId: String, chatId: String, createdAt: Double, payload: Data, state: String = "ready") {
        self.clientMsgId = clientMsgId
        self.chatId = chatId
        self.createdAt = createdAt
        self.payload = payload
        self.state = state
    }
}

/// Расшифрованный контент сообщения (внутри E2E-конверта).
public struct ContentPayload: Codable {
    public var kind: String
    public var text: String?
    public var media: MediaInfo?
    public var album: [MediaInfo]?
    public var replyTo: ReplyPreview?
    public var fwd: ForwardInfo?
    public var targetMsgId: String?   // edit / reaction
    public var emoji: String?         // reaction (nil = снять)
    public var ttlSeconds: Int?       // disappearing setting

    public init(kind: String) { self.kind = kind }
}

/// Сервисное действие, ждущее сети: read receipt, delete-for-all, accept заявки.
/// Дренится воркером SyncEngine при connected; все действия идемпотентны.
public struct PendingAction: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "pendingAction"
    public var id: String
    public var type: String     // read | delete | accept
    public var chatId: String
    public var payload: String  // JSON, формат зависит от type
    public var createdAt: Double
    public var attempts: Int = 0

    public init(id: String, type: String, chatId: String, payload: String, createdAt: Double) {
        self.id = id
        self.type = type
        self.chatId = chatId
        self.payload = payload
        self.createdAt = createdAt
    }
}

public struct KVRow: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "kv"
    public var key: String
    public var value: String
    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}
