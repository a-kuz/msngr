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

public enum ChatKind: String, Codable {
    case direct, group
    /// The chat with yourself: one per user, its only member is the owner.
    case saved = "self"
}

public struct Chat: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "chat"
    public var id: String
    public var kind: ChatKind
    public var title: String?
    public var avatarId: String?
    public var chatDescription: String?
    /// group rights, as the server states them: "all" or "admins"
    public var sendPolicy: String = ChatPermissions.openPolicy
    public var invitePolicy: String = ChatPermissions.openPolicy
    public var createdBy: String
    public var createdAt: Double
    /// pinned messages by seq, the newest pin last
    public var pinnedSeqs: [Int] = []
    /// last seq on the server (from state) and the last one applied locally
    public var lastSeq: Int
    public var syncedSeq: Int
    /// how far the server has replayed the chat journal: the catch-up boundary
    /// acknowledged batch by batch, from which it resumes after a drop
    public var syncCursor: Int = 0
    // local attributes
    public var unreadCount: Int = 0
    public var pinned: Bool = false
    public var muted: Bool = false
    /// when mute expires; nil while muted means indefinitely
    public var mutedUntil: Double?
    public var archived: Bool = false
    public var draft: String?
    public var myReadUpTo: Int = 0
    /// how far the member furthest behind has got: the tick of a message speaks
    /// for the whole chat (`chatMark` holds the marks it is taken from)
    public var peerReadUpTo: Int = 0
    public var peerDeliveredUpTo: Int = 0
    public var ttlSeconds: Int = 0          // disappearing messages
    /// message request: the chat sits in Requests for the recipient until they accept
    public var isRequest: Bool = false
    /// whether I accepted this chat (recipient side of a direct chat)
    public var iAccepted: Bool = true
    /// orders the chat list
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
    public var key: String         // b64 key
    public var hash: String        // b64 sha256 ciphertext
    public var size: Int
    public var mime: String
    public var name: String?
    public var w: Int?
    public var h: Int?
    public var dur: Double?
    public var waveform: [Int]?    // 0..31, up to 100 buckets
    public var blurhash: String?
    public var thumbMediaId: String?  // video preview frame, a blob of its own
    public var thumbKey: String?
    public var thumbHash: String?
    /// name of the local file in MediaManager.pendingDir while the media is not
    /// uploaded yet (mediaId empty); the outbox worker uploads it and fills in
    /// mediaId, key and hash
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
    /// seq of the quoted message; nil when it had none yet (an own message
    /// quoted before its ack), in which case the quote shows but cannot jump.
    public var seq: Int?
    public var authorId: String
    public var text: String     // short preview
    public var kind: String

    public init(seq: Int?, authorId: String, text: String, kind: String) {
        self.seq = seq
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

/// One superseded text of an edited message: what it said and when that text
/// was authored (the original's `sentAt`, or the `sentAt` of the edit that
/// produced it).
public struct EditVersion: Codable, Equatable {
    public var text: String
    public var ts: Double
    public init(text: String, ts: Double) {
        self.text = text
        self.ts = ts
    }
}

public struct Message: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "message"
    /// local id: clientMsgId for own messages, "<chatId>/<seq>" for everyone else's
    public var id: String
    public var chatId: String
    public var seq: Int?               // null until ack
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
    /// Superseded texts, oldest first; the original text is [0] once edited.
    public var editHistory: [EditVersion] = []
    /// When the current text was authored; nil until the first edit.
    public var editedAt: Double?
    public var deletedForAll: Bool = false
    public var status: MessageStatus
    public var isOutgoing: Bool
    /// reactions: emoji -> [userId]
    public var reactions: [String: [String]] = [:]
    public var expiresAt: Double?      // disappearing
    /// why it failed when status == .failed (codes live in SendFailure)
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

    // JSON columns
    enum CodingKeys: String, CodingKey {
        case id, chatId, seq, clientMsgId, fromUserId, sentAt, serverTs,
             kind, text, media, album, replyTo, forward, edited, editHistory,
             editedAt, deletedForAll, status, isOutgoing, reactions, expiresAt,
             failReason
    }

    /// Local row id of a message the server numbered: the identity every
    /// incoming reference resolves through.
    public static func feedId(chatId: String, seq: Int) -> String {
        "\(chatId)/\(seq)"
    }
}

public struct OutboxItem: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "outbox"
    public var clientMsgId: String
    public var chatId: String
    public var createdAt: Double
    public var attempts: Int = 0
    /// plaintext content (ContentPayload as JSON), encrypted when it is sent
    public var payload: Data
    /// ready (waiting to be sent) | inflight (sent, waiting for the ack)
    public var state: String = "ready"

    public init(clientMsgId: String, chatId: String, createdAt: Double, payload: Data, state: String = "ready") {
        self.clientMsgId = clientMsgId
        self.chatId = chatId
        self.createdAt = createdAt
        self.payload = payload
        self.state = state
    }
}

/// Decrypted message content, the thing an E2E envelope carries.
public struct ContentPayload: Codable {
    public var kind: String
    public var text: String?
    public var media: MediaInfo?
    public var album: [MediaInfo]?
    public var replyTo: ReplyPreview?
    public var fwd: ForwardInfo?
    /// edit / reaction: seq of the message the event lands on. Filled at send
    /// time from the local row (`targetLocalId`); the peer applies by it.
    public var targetSeq: Int?
    /// edit / reaction, local only: row id of the target while it may still be
    /// waiting for its ack. Resolved into `targetSeq` and stripped before the
    /// payload is encrypted.
    public var targetLocalId: String?
    public var emoji: String?         // reaction (nil clears it)
    public var ttlSeconds: Int?       // disappearing setting
    /// Encrypt pairwise to this user alone, whatever kind the chat is. Repair
    /// traffic concerns two devices, so it never travels on a group chain.
    public var to: String?
    /// repairRequest: seq of the message that could not be read, and why.
    public var repairSeq: Int?
    public var reason: String?
    /// repairRequest / repair: which attempt this is. The id built from it keeps
    /// a repeated request from reaching the sender twice.
    public var attempt: Int?
    /// repair: when the restored copy was sent, and the original content as
    /// JSON. `repairSeq` names the message; the receiver stores the copy under
    /// (chatId, repairSeq), so it takes its own place in the feed.
    public var origSentAt: Double?
    public var orig: String?
    /// skdAck: the sender key chain the recipient stored.
    public var keyId: String?

    public init(kind: String) { self.kind = kind }
}

/// A service action waiting for the network: read receipt, delete-for-all, accepting
/// a request. Drained by the SyncEngine worker once connected; all of them are idempotent.
public struct PendingAction: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "pendingAction"
    public var id: String
    public var type: String     // read | delete | accept | deleteChat | block
    /// nil for actions not tied to a chat (blocking a peer).
    public var chatId: String?
    public var payload: String  // JSON, shape depends on type
    public var createdAt: Double
    public var attempts: Int = 0

    public init(id: String, type: String, chatId: String?, payload: String, createdAt: Double) {
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
