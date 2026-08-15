import Foundation

/// Versions this build speaks. Both travel with the data they describe: the
/// protocol version in the socket upgrade, the envelope version inside every
/// E2E envelope. Neither promises compatibility (see docs/PROCESS.md) — they
/// are what turns a mismatch into a state the app can name instead of a
/// silence or a crash.
public enum MsngrProtocol {
    /// Wire protocol of the socket. The server refuses an upgrade below its own
    /// floor, and the app says it has to be updated.
    public static let version = 1

    /// Highest E2E envelope format this build can open. An envelope above it is
    /// unreadable here, and no repair round changes that.
    public static let envelopeVersion = 1

    /// The socket URL with this build's version on it.
    public static func versioned(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = comps.queryItems ?? []
        items.removeAll { $0.name == "v" }
        items.append(URLQueryItem(name: "v", value: String(version)))
        comps.queryItems = items
        return comps.url ?? url
    }
}

/// Зеркало серверного протокола (docs/protocol.md).
public enum WSOutgoing {
    /// весь известный клиенту мир: чаты, которых нет в курсорах, сервер
    /// присылает состоянием и доигрывает с нуля
    case sync(cursors: [String: Int])
    /// следующая порция догона по чатам, которые ещё отстают
    case catchup(cursors: [String: Int])
    // service: служебный фрейм (skd/reaction/edit/disappearing) — сервер не растит им unread/бейдж
    case send(chatId: String, clientMsgId: String, sentAt: Double, body: Envelope, service: Bool)
    case recv(chatId: String, seqs: [Int])
    case read(chatId: String, upToSeq: Int)
    case typing(chatId: String, kind: String?)
    case delete(chatId: String, msgIds: [String], forAll: Bool)
    case ping

    public func encode() throws -> Data {
        var obj: [String: Any]
        switch self {
        case .sync(let cursors):
            obj = ["t": "sync", "cursors": cursors]
        case .catchup(let cursors):
            obj = ["t": "catchup", "cursors": cursors]
        case .send(let chatId, let clientMsgId, let sentAt, let body, let service):
            obj = ["t": "send", "chatId": chatId, "clientMsgId": clientMsgId,
                   "sentAt": sentAt, "body": try body.jsonObject()]
            if service { obj["service"] = true }
        case .recv(let chatId, let seqs):
            obj = ["t": "recv", "chatId": chatId, "seqs": seqs]
        case .read(let chatId, let upToSeq):
            obj = ["t": "read", "chatId": chatId, "upToSeq": upToSeq]
        case .typing(let chatId, let kind):
            obj = ["t": "typing", "chatId": chatId, "kind": kind as Any]
        case .delete(let chatId, let msgIds, let forAll):
            obj = ["t": "delete", "chatId": chatId, "msgIds": msgIds, "forAll": forAll]
        case .ping:
            obj = ["t": "ping"]
        }
        return try JSONSerialization.data(withJSONObject: obj)
    }
}

/// E2E-конверт. pw: per-device ciphertext'ы; skm: sender-key message;
/// skd вложен в pw (раздача sender key — обычное pairwise-сообщение).
public struct Envelope: Codable {
    public var v: Int = MsngrProtocol.envelopeVersion
    public var mode: String            // "pw" | "skm"
    public var msgs: [String: PairwiseBox]?   // "userId/deviceId" -> box
    public var c: String?              // skm ciphertext b64
    public var keyId: String?
    public var iteration: UInt32?
    public var sig: String?

    public init(mode: String) { self.mode = mode }

    func jsonObject() throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(self))
    }
}

/// Одно pairwise-сообщение: pk (prekey, первое) или dr (ratchet).
public struct PairwiseBox: Codable {
    public var type: String   // "pk" | "dr"
    public var c: String      // b64 RatchetMessage(header+ciphertext) JSON
    // для pk:
    public var ik: String?    // наш identity DH pub b64
    public var isk: String?   // наш identity signing pub b64
    public var ek: String?    // ephemeral pub b64
    public var spkId: UInt32? // какой signed prekey использован
    public var otpId: UInt32? // какой one-time prekey использован

    public init(type: String, c: String) {
        self.type = type
        self.c = c
    }
}

public struct WSIncoming: Decodable {
    public let t: String
    // общие поля (опциональны по типам)
    public let chatId: String?
    public let clientMsgId: String?
    public let msgId: String?
    public let seq: Int?
    public let ts: Double?
    public let from: String?
    public let fromDevice: String?
    public let sentAt: Double?
    public let body: JSONValue?
    public let kind: String?
    public let upToSeq: Int?
    public let seqs: [Int]?
    public let by: String?
    public let userId: String?
    public let online: Bool?
    public let lastSeen: Double?
    public let event: String?
    public let state: ChatStateDTO?
    public let msgIds: [String]?
    public let forAll: Bool?
    public let serverTime: Double?
    /// msg: служебный фрейм (skd/reaction/edit) — не растит unread
    public let service: Bool?
    /// error: машиночитаемый код отказа по нашему фрейму (см. SendFailure)
    public let error: String?
    /// syncState: seq, по который догон чата дошёл в этой порции
    public let cursor: Int?
    /// syncState: у чата есть история дальше курсора;
    /// syncDone: порция закрыта, но догон не закончен
    public let more: Bool?
}

public struct ChatStateDTO: Decodable {
    public struct MemberDTO: Decodable {
        public let userId: String
        public let role: String
        public let joinedAt: Double
        public let accepted: Bool?
    }
    public let chatId: String
    public let kind: String
    public let title: String?
    public let avatarId: String?
    public let description: String?
    public let createdBy: String
    public let createdAt: Double
    public let members: [MemberDTO]
    public let pinnedMsgId: String?
    public let lastSeq: Int
    public let readMarks: [String: Int]
    public let deliveredMarks: [String: Int]
}

/// Минимальный произвольный JSON (для body до расшифровки).
public enum JSONValue: Codable, Sendable {
    case string(String), number(Double), bool(Bool), null
    case array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    public var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public func decoded<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
