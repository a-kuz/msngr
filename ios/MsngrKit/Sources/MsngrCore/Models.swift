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
    /// A bot: the account that owns it. A bot has no keys, so a chat it is in
    /// is not end-to-end encrypted.
    public var botOwner: String?
    /// A bot's commands, as the JSON the server keeps: `[{command, description}]`.
    public var botCommands: String?

    public var isBot: Bool { botOwner != nil }

    /// The commands this bot offers, parsed; empty for a person.
    public var commands: [BotCommand] {
        guard let botCommands, let data = botCommands.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([BotCommand].self, from: data)) ?? []
    }

    public init(id: String, username: String, displayName: String,
                bio: String? = nil, avatarId: String? = nil) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.bio = bio
        self.avatarId = avatarId
    }
}

/// One command a bot offers: the word typed after «/» and what it does.
public struct BotCommand: Codable, Equatable, Identifiable, Sendable {
    public let command: String
    public let description: String
    public var id: String { command }

    public init(command: String, description: String) {
        self.command = command
        self.description = description
    }
}

/// A button under a bot's message. Tapping it sends the bot a `callback`
/// content carrying `data`; the reader sees the text.
public struct MessageButton: Codable, Equatable, Identifiable, Sendable {
    public let text: String
    public let data: String
    public var id: String { data }

    public init(text: String, data: String) {
        self.text = text
        self.data = data
    }
}

/// How far one member of a chat has got, read straight from `chatMark`.
public struct MemberMark: Equatable {
    public let deliveredUpTo: Int
    public let readUpTo: Int
    public init(deliveredUpTo: Int, readUpTo: Int) {
        self.deliveredUpTo = deliveredUpTo
        self.readUpTo = readUpTo
    }
}

public enum ChatKind: String, Codable {
    case direct, group
    /// The chat with yourself: one per user, its only member is the owner.
    case saved = "self"
    /// A channel: the owner and the editors post, everyone else reads and
    /// comments. The one kind that is not end-to-end encrypted — its posts are
    /// journaled in the clear so the server can search them and hand the whole
    /// history to whoever subscribes later. The interface says so plainly.
    case channel
}

/// What someone may do in the chat they are in. A group has admins and members;
/// a channel has an owner, editors who post and readers who comment.
public enum ChatRole: String, Codable {
    case admin, member, owner, editor, reader

    /// Whether this role may put a post into a channel.
    public var postsToChannel: Bool { self == .owner || self == .editor }
}

public struct Chat: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "chat"
    public var id: String
    public var kind: ChatKind
    public var title: String?
    public var avatarId: String?
    public var chatDescription: String?
    /// The chat's content is journaled readable: a channel, or a chat a bot is
    /// in. Envelopes are sent and opened in the clear here and nowhere else.
    public var plaintext: Bool = false
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
    case text, photo, video, file, voice, album, contact, system, shader, sticker, roundVideo, poll,
         location, call
}

/// A person's card as the sender shared it: what the contact picker handed
/// over, not a reference into anyone's address book.
public struct ContactCard: Codable, Equatable {
    public var name: String
    public var phones: [String]
    public var emails: [String]

    public init(name: String, phones: [String], emails: [String] = []) {
        self.name = name
        self.phones = phones
        self.emails = emails
    }
}

/// A point on the map. `name` is the label the sender picked it under — a
/// place or an address; the receiver renders the coordinate, never resolves it.
public struct LocationInfo: Codable, Equatable {
    public var lat: Double
    public var lon: Double
    public var name: String?

    public init(lat: Double, lon: Double, name: String? = nil) {
        self.lat = lat
        self.lon = lon
        self.name = name
    }
}

/// A poll as its author composed it. Votes travel separately, as `pollVote`
/// service events, and are aggregated on every device; anonymity is a display
/// promise — the events themselves always name their sender, the way any
/// end-to-end encrypted frame does.
public struct PollInfo: Codable, Equatable {
    public var question: String
    public var options: [String]
    /// several answers may be picked at once
    public var multiple: Bool
    /// the voters' names are not shown (the count still is)
    public var anonymous: Bool

    public init(question: String, options: [String], multiple: Bool, anonymous: Bool) {
        self.question = question
        self.options = options
        self.multiple = multiple
        self.anonymous = anonymous
    }
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

/// The card under a text message that carries a link: the page's title,
/// description and picture, fetched by the sender's client and carried inside
/// the encrypted payload — the server never sees the page, and the receiver
/// never fetches it.
public struct LinkPreview: Codable, Equatable {
    public var url: String
    public var title: String
    public var desc: String?
    /// The page's picture, travelling like any other media: encrypted, in R2.
    public var image: MediaInfo?

    public init(url: String, title: String, desc: String? = nil, image: MediaInfo? = nil) {
        self.url = url
        self.title = title
        self.desc = desc
        self.image = image
    }

    /// What the card's third line shows: the page's host, without "www.".
    public var host: String? {
        guard let h = URL(string: url)?.host else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
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
    /// kind == .shader or .sticker: the passes and their channel wiring
    public var shader: ShaderDocument?
    /// A shader the sender chose to paint behind the bubble of a text message.
    public var bubbleShader: ShaderDocument?
    /// text: the card of the first link, built on the sender's device.
    public var linkPreview: LinkPreview?
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
    /// when this outgoing message is due to be sent; nil once it has, or for
    /// a message that was never scheduled
    public var scheduledFor: Double?
    /// voice / roundVideo: when this device started playing it. Local only —
    /// it never travels — and it is what the play-one-after-another chain
    /// walks past: a note already listened to does not start again on its own.
    public var listenedAt: Double?
    /// voice / roundVideo: who has started listening, filled by the peers'
    /// `listened` events. What the sender's listened dots are drawn from.
    public var listenedBy: [String] = []
    /// poll: the question and its options.
    public var poll: PollInfo?
    /// poll: userId -> chosen option indices, aggregated from `pollVote`
    /// events. A retraction removes the user's entry.
    public var pollVotes: [String: [Int]] = [:]
    /// contact: the shared card.
    public var contact: ContactCard?
    /// location: the shared point.
    public var location: LocationInfo?
    /// A bot's buttons under the message, a row per array.
    public var buttons: [[MessageButton]]?
    /// voice: the on-device transcript, recognized on demand. Local only —
    /// it never travels.
    public var transcript: String?
    /// voice: the transcript's word timings; concatenating the spans' text
    /// yields `transcript` exactly.
    public var transcriptSpans: [TranscriptSpan] = []
    /// voice: whether the transcript is unfolded under the waveform.
    public var transcriptShown: Bool = false

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
             kind, text, media, album, replyTo, forward, shader, bubbleShader, edited, editHistory,
             editedAt, deletedForAll, status, isOutgoing, reactions, expiresAt,
             failReason, scheduledFor, listenedAt, listenedBy, poll, pollVotes,
             contact, location, buttons,
             transcript, transcriptSpans, transcriptShown
    }

    /// Local row id of a message the server numbered: the identity every
    /// incoming reference resolves through.
    public static func feedId(chatId: String, seq: Int) -> String {
        "\(chatId)/\(seq)"
    }
}

/// A stretch of a voice transcript with the seconds it was spoken at: what the
/// playback highlight walks along.
public struct TranscriptSpan: Codable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }

    /// How much of the concatenated transcript is spoken by `time`, in UTF-16
    /// units (what an NSRange over the drawn text counts in), interpolated
    /// inside the current span so the highlight moves smoothly rather than
    /// jumping a word at a stride.
    public static func spokenLength(_ spans: [TranscriptSpan], at time: Double) -> Int {
        var length = 0.0
        for span in spans {
            if time >= span.end {
                length += Double(span.text.utf16.count)
            } else if time > span.start {
                let f = (time - span.start) / max(span.end - span.start, 0.001)
                length += Double(span.text.utf16.count) * f
            }
        }
        return Int(length.rounded())
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
    /// ready (waiting to be sent) | inflight (sent, waiting for the ack) |
    /// deferred (the server holds the envelope and journals it at scheduledFor)
    public var state: String = "ready"
    /// when a scheduled send is due, seconds since epoch; nil sends at once.
    /// The drain hands it to the server as a deferred envelope right away,
    /// and the server's `sent` at the deadline closes this row
    public var scheduledFor: Double?

    public init(clientMsgId: String, chatId: String, createdAt: Double, payload: Data,
               state: String = "ready", scheduledFor: Double? = nil) {
        self.clientMsgId = clientMsgId
        self.chatId = chatId
        self.createdAt = createdAt
        self.payload = payload
        self.state = state
        self.scheduledFor = scheduledFor
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
    /// shader / sticker: the passes and their channel wiring, rendered on the receiver
    public var shader: ShaderDocument?
    /// text: a shader painted behind the bubble, the sender's choice
    public var bubbleShader: ShaderDocument?
    /// text: the link card the sender built; the receiver renders, never fetches
    public var preview: LinkPreview?
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
    /// poll: the question and its options.
    public var poll: PollInfo?
    /// pollVote: the chosen option indices; empty retracts the vote.
    public var votes: [Int]?
    /// contact: the shared card.
    public var contact: ContactCard?
    /// location: the shared point.
    public var location: LocationInfo?
    /// A bot's message can carry buttons under it, a row per array.
    public var buttons: [[MessageButton]]?
    /// callback: what the pressed button carries back to the bot.
    public var data: String?

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
