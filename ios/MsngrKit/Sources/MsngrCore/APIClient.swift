import Foundation

public struct APIError: Error, Equatable {
    public let code: String
    public let status: Int
}

/// HTTP-клиент серверного API. Все методы — async, ошибки типизированы.
public final class APIClient: @unchecked Sendable {
    public let baseURL: URL
    public var token: String?
    private let session: URLSession

    public init(baseURL: URL, token: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    private func request(_ path: String, method: String = "GET",
                         jsonBody: Encodable? = nil, rawBody: Data? = nil,
                         contentType: String? = nil) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let jsonBody {
            req.httpBody = try JSONEncoder().encode(jsonBody)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let rawBody {
            req.httpBody = rawBody
            req.setValue(contentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 400 {
            let err = try? JSONDecoder().decode(ErrBody.self, from: data)
            throw APIError(code: err?.error ?? "http_\(status)", status: status)
        }
        return data
    }

    private struct ErrBody: Decodable { let error: String? }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await request(path))
    }

    private func post<T: Decodable>(_ path: String, body: Encodable, as type: T.Type) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await request(path, method: "POST", jsonBody: body))
    }

    // MARK: - Auth

    public struct RegisterRequest: Encodable {
        public var username: String
        public var displayName: String
        public var device: [String: String]
        public var identityKey: String
        public var identitySignKey: String
        public var signedPrekey: SignedPrekeyDTO
        public var oneTimePrekeys: [OneTimePrekeyDTO]
        public var phoneHash: String?
        public struct SignedPrekeyDTO: Codable {
            public var id: UInt32
            public var key: String
            public var sig: String
            public init(id: UInt32, key: String, sig: String) {
                self.id = id; self.key = key; self.sig = sig
            }
        }
        public struct OneTimePrekeyDTO: Codable {
            public var id: UInt32
            public var key: String
            public init(id: UInt32, key: String) { self.id = id; self.key = key }
        }
        public init(username: String, displayName: String, deviceName: String,
                    identityKey: String, identitySignKey: String,
                    signedPrekey: SignedPrekeyDTO, oneTimePrekeys: [OneTimePrekeyDTO],
                    phoneHash: String?) {
            self.username = username
            self.displayName = displayName
            self.device = ["name": deviceName]
            self.identityKey = identityKey
            self.identitySignKey = identitySignKey
            self.signedPrekey = signedPrekey
            self.oneTimePrekeys = oneTimePrekeys
            self.phoneHash = phoneHash
        }
    }

    public struct RegisterResponse: Decodable {
        public let userId: String
        public let deviceId: String
        public let token: String
    }

    public func register(_ body: RegisterRequest) async throws -> RegisterResponse {
        try await post("api/register", body: body, as: RegisterResponse.self)
    }

    // MARK: - Users / prekeys

    public struct UserDTO: Decodable {
        public let id: String
        public let username: String
        public let display_name: String
        public let bio: String?
        public let avatar_id: String?
    }

    public struct SearchResponse: Decodable { public let users: [UserDTO] }
    public func searchUsers(_ q: String) async throws -> [UserDTO] {
        let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        return try await get("api/users?q=\(encoded)", as: SearchResponse.self).users
    }

    public struct PresenceDTO: Decodable {
        public let online: Bool
        public let lastSeen: Double
    }
    public struct UserResponse: Decodable {
        public let user: UserDTO
        public let presence: PresenceDTO?
    }
    public func user(_ id: String) async throws -> UserResponse {
        try await get("api/users/\(id)", as: UserResponse.self)
    }

    public struct PrekeyBundleDTO: Decodable {
        public let deviceId: String
        public let identityKey: String
        public let identitySignKey: String
        public let signedPrekey: SignedPrekeyBody
        public let oneTimePrekey: OneTimePrekeyBody?
        public struct SignedPrekeyBody: Decodable {
            public let id: UInt32
            public let key: String
            public let sig: String
        }
        public struct OneTimePrekeyBody: Decodable {
            public let id: UInt32
            public let key: String
        }
    }
    public struct PrekeysResponse: Decodable {
        public let userId: String
        public let bundles: [PrekeyBundleDTO]
    }
    public func prekeys(userId: String) async throws -> PrekeysResponse {
        try await get("api/users/\(userId)/prekeys", as: PrekeysResponse.self)
    }

    public func uploadPrekeys(_ keys: [RegisterRequest.OneTimePrekeyDTO]) async throws {
        struct Body: Encodable { let oneTimePrekeys: [RegisterRequest.OneTimePrekeyDTO] }
        _ = try await request("api/prekeys", method: "POST", jsonBody: Body(oneTimePrekeys: keys))
    }

    // MARK: - Chats

    public struct CreateChatResponse: Decodable { public let chatId: String }
    public func createChat(kind: String, memberIds: [String], title: String?) async throws -> String {
        struct Body: Encodable { let kind: String; let memberIds: [String]; let title: String? }
        return try await post("api/chats", body: Body(kind: kind, memberIds: memberIds, title: title),
                              as: CreateChatResponse.self).chatId
    }

    public struct ChatsSnapshot: Decodable {
        public struct Entry: Decodable {
            public let flags: Flags
            public let state: ChatStateDTO
            public struct Flags: Decodable {
                public let pinned: Bool
                public let muted: Bool
                public let archived: Bool
            }
        }
        public let chats: [Entry]
        public let users: [UserDTO]
    }
    public func chatsSnapshot() async throws -> ChatsSnapshot {
        try await get("api/chats", as: ChatsSnapshot.self)
    }

    public struct HistoryResponse: Decodable {
        public struct MsgDTO: Decodable {
            public let msgId: String
            public let seq: Int
            public let from: String
            public let fromDevice: String
            public let sentAt: Double
            public let ts: Double
            public let body: JSONValue?
            public let deleted: Bool?
        }
        public let msgs: [MsgDTO]
    }
    public func history(chatId: String, fromSeq: Int, toSeq: Int? = nil,
                        limit: Int = 100, back: Bool = false) async throws -> [HistoryResponse.MsgDTO] {
        var path = "api/chats/\(chatId)/history?fromSeq=\(fromSeq)&limit=\(limit)"
        if let toSeq { path += "&toSeq=\(toSeq)" }
        if back { path += "&dir=back" }
        return try await get(path, as: HistoryResponse.self).msgs
    }

    public func acceptChat(_ chatId: String) async throws {
        _ = try await request("api/chats/\(chatId)/accept", method: "POST", jsonBody: [String: String]())
    }
    public func leaveChat(_ chatId: String) async throws {
        _ = try await request("api/chats/\(chatId)/leave", method: "POST", jsonBody: [String: String]())
    }
    public func updateMembers(_ chatId: String, add: [String], remove: [String]) async throws {
        struct Body: Encodable { let add: [String]; let remove: [String] }
        _ = try await request("api/chats/\(chatId)/members", method: "POST", jsonBody: Body(add: add, remove: remove))
    }
    public func chatSettings(_ chatId: String, title: String? = nil,
                             avatarId: String? = nil, description: String? = nil) async throws {
        struct Body: Encodable { let title: String?; let avatarId: String?; let description: String? }
        _ = try await request("api/chats/\(chatId)/settings", method: "POST",
                              jsonBody: Body(title: title, avatarId: avatarId, description: description))
    }
    public func setAdmin(_ chatId: String, userId: String, admin: Bool) async throws {
        struct Body: Encodable { let userId: String; let admin: Bool }
        _ = try await request("api/chats/\(chatId)/admins", method: "POST", jsonBody: Body(userId: userId, admin: admin))
    }
    public func pinMessage(_ chatId: String, msgId: String?) async throws {
        struct Body: Encodable { let msgId: String? }
        _ = try await request("api/chats/\(chatId)/pin-message", method: "POST", jsonBody: Body(msgId: msgId))
    }
    public func setChatFlags(_ chatId: String, pinned: Bool? = nil,
                             muted: Bool? = nil, archived: Bool? = nil) async throws {
        struct Body: Encodable { let pinned: Bool?; let muted: Bool?; let archived: Bool? }
        _ = try await request("api/chats/\(chatId)/flags", method: "POST",
                              jsonBody: Body(pinned: pinned, muted: muted, archived: archived))
    }

    public struct InviteResponse: Decodable {
        public let code: String
        public let link: String
    }
    public func createInvite(_ chatId: String) async throws -> InviteResponse {
        try await post("api/chats/\(chatId)/invite", body: [String: String](), as: InviteResponse.self)
    }
    public struct JoinResponse: Decodable { public let chatId: String }
    public func join(code: String) async throws -> String {
        try await post("api/join/\(code)", body: [String: String](), as: JoinResponse.self).chatId
    }

    // MARK: - Media

    public struct MediaUploadResponse: Decodable {
        public let mediaId: String
        public let size: Int
    }
    public func uploadMedia(_ data: Data) async throws -> MediaUploadResponse {
        let raw = try await request("api/media", method: "POST", rawBody: data)
        return try JSONDecoder().decode(MediaUploadResponse.self, from: raw)
    }
    public func downloadMedia(_ mediaId: String) async throws -> Data {
        try await request("api/media/\(mediaId)")
    }
    public func mediaURL(_ mediaId: String) -> URL {
        baseURL.appendingPathComponent("api/media/\(mediaId)")
    }
    public struct AvatarResponse: Decodable { public let avatarId: String }
    public func uploadAvatar(_ jpeg: Data) async throws -> String {
        let raw = try await request("api/avatar", method: "POST", rawBody: jpeg, contentType: "image/jpeg")
        return try JSONDecoder().decode(AvatarResponse.self, from: raw).avatarId
    }
    public func avatarURL(_ avatarId: String) -> URL {
        baseURL.appendingPathComponent("api/avatar/\(avatarId)")
    }

    // MARK: - Profile / contacts / misc

    public func updateProfile(displayName: String? = nil, bio: String? = nil, avatarId: String? = nil) async throws {
        struct Body: Encodable { let displayName: String?; let bio: String?; let avatarId: String? }
        _ = try await request("api/profile", method: "POST", jsonBody: Body(displayName: displayName, bio: bio, avatarId: avatarId))
    }

    public struct DiscoverResponse: Decodable {
        public struct Match: Decodable {
            public let id: String
            public let username: String
            public let display_name: String
            public let avatar_id: String?
            public let phone_hash: String
        }
        public let matches: [Match]
    }
    public func discoverContacts(hashes: [String]) async throws -> [DiscoverResponse.Match] {
        struct Body: Encodable { let hashes: [String] }
        return try await post("api/contacts/discover", body: Body(hashes: hashes), as: DiscoverResponse.self).matches
    }
    public func setPhoneHash(_ hash: String?) async throws {
        struct Body: Encodable { let phoneHash: String? }
        _ = try await request("api/phone", method: "POST", jsonBody: Body(phoneHash: hash))
    }

    public func registerPushToken(_ token: String, env: String) async throws {
        struct Body: Encodable { let apnsToken: String; let env: String }
        _ = try await request("api/push-token", method: "POST", jsonBody: Body(apnsToken: token, env: env))
    }

    public func setBlocked(_ userId: String, blocked: Bool) async throws {
        struct Body: Encodable { let userId: String; let blocked: Bool }
        _ = try await request("api/block", method: "POST", jsonBody: Body(userId: userId, blocked: blocked))
    }
    public struct BlockedResponse: Decodable { public let blocked: [String] }
    public func blockedUsers() async throws -> [String] {
        try await get("api/blocked", as: BlockedResponse.self).blocked
    }
}
