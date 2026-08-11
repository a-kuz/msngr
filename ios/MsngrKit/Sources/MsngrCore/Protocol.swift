import Foundation

/// Зеркало серверного протокола (docs/protocol.md).
public enum WSOutgoing {
    case sync(cursors: [String: Int])
    case send(chatId: String, clientMsgId: String, sentAt: Double, body: Envelope)
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
        case .send(let chatId, let clientMsgId, let sentAt, let body):
            obj = ["t": "send", "chatId": chatId, "clientMsgId": clientMsgId,
                   "sentAt": sentAt, "body": try body.jsonObject()]
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
    public var v: Int = 1
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
public enum JSONValue: Codable {
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
