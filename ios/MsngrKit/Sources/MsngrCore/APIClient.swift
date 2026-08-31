import Foundation

public struct APIError: Error, Equatable {
    public let code: String
    public let status: Int
}

/// HTTP client for the server API. Every method is async and errors are typed.
public final class APIClient: @unchecked Sendable {
    public let baseURL: URL
    public var token: String?
    private let session: URLSession

    /// The session API calls run on. A request that hangs is worse than one that
    /// fails: a stale connection (the far side of a tunnel restarted, a network
    /// switch the socket never noticed) swallows requests silently, and the
    /// default 60 s is a frozen screen. 15 s turns it into a failure the caller's
    /// retry can act on.
    private static let apiSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()

    public init(baseURL: URL, token: String? = nil, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.token = token
        self.session = session ?? APIClient.apiSession
    }

    /// Builds a URL from a path that may carry a query string. appendingPathComponent
    /// escapes "?" as %3F, which folds the query into the path and turns the request into a 404.
    private func url(for path: String) -> URL {
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var url = baseURL.appendingPathComponent(String(parts[0]))
        if parts.count > 1, !parts[1].isEmpty,
           var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.percentEncodedQuery = String(parts[1])
            url = comps.url ?? url
        }
        return url
    }

    private func request(_ path: String, method: String = "GET",
                         jsonBody: Encodable? = nil, rawBody: Data? = nil,
                         contentType: String? = nil) async throws -> Data {
        var req = URLRequest(url: url(for: path))
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
        public var identityKeySig: String
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
                    identityKey: String, identitySignKey: String, identityKeySig: String,
                    signedPrekey: SignedPrekeyDTO, oneTimePrekeys: [OneTimePrekeyDTO],
                    phoneHash: String?) {
            self.username = username
            self.displayName = displayName
            self.device = ["name": deviceName]
            self.identityKey = identityKey
            self.identitySignKey = identitySignKey
            self.identityKeySig = identityKeySig
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

    public struct MeResponse: Decodable {
        public let user: UserDTO
        public let deviceId: String
    }
    public func me() async throws -> MeResponse {
        try await get("api/me", as: MeResponse.self)
    }

    // MARK: - Signing in on a new device

    /// A provisioning session is the one thing a device without an account can
    /// hold, so its calls carry the session's own secret instead of a device
    /// token. Everything else on this client speaks `Authorization: Bearer`.
    private func provisionRequest<T: Decodable>(_ path: String, provisionToken: String,
                                                method: String = "GET", body: Encodable? = nil,
                                                as type: T.Type) async throws -> T {
        var req = URLRequest(url: url(for: path))
        req.httpMethod = method
        req.setValue(provisionToken, forHTTPHeaderField: "x-provision-token")
        if let body {
            req.httpBody = try JSONEncoder().encode(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 400 {
            let err = try? JSONDecoder().decode(ErrBody.self, from: data)
            throw APIError(code: err?.error ?? "http_\(status)", status: status)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    public struct ProvisionStartResponse: Decodable, Sendable {
        public let provisionId: String
        public let code: String
        public let provisionToken: String
        public let expiresIn: Double
    }
    private struct ProvisionStartRequest: Encodable {
        let ephemeralKey: String
        let device: [String: String]
    }
    public func provisionStart(ephemeralKey: String, deviceName: String,
                               platform: String) async throws -> ProvisionStartResponse {
        try await post("api/provision/start",
                       body: ProvisionStartRequest(ephemeralKey: ephemeralKey,
                                                   device: ["name": deviceName, "platform": platform]),
                       as: ProvisionStartResponse.self)
    }

    public struct ProvisionStatusResponse: Decodable, Sendable {
        public let status: String
        public let envelope: String?
    }
    public func provisionStatus(_ provisionId: String,
                                provisionToken: String) async throws -> ProvisionStatusResponse {
        try await provisionRequest("api/provision/\(provisionId)", provisionToken: provisionToken,
                                   as: ProvisionStatusResponse.self)
    }

    public struct ProvisionLookupResponse: Decodable, Sendable {
        public let provisionId: String
        public let ephemeralKey: String
        public let device: DeviceInfo
        public let expiresIn: Double
        public struct DeviceInfo: Decodable, Sendable {
            public let name: String?
            public let platform: String?
        }
    }
    public func provisionLookup(code: String) async throws -> ProvisionLookupResponse {
        try await post("api/provision/lookup", body: ["code": code],
                       as: ProvisionLookupResponse.self)
    }

    private struct OkResponse: Decodable { let ok: Bool }
    public func provisionApprove(_ provisionId: String, envelope: String) async throws {
        _ = try await post("api/provision/\(provisionId)/approve",
                           body: ["envelope": envelope], as: OkResponse.self)
    }

    public struct ProvisionClaimRequest: Encodable {
        public var identityKey: String
        public var identitySignKey: String
        public var identityKeySig: String
        public var signedPrekey: RegisterRequest.SignedPrekeyDTO
        public var oneTimePrekeys: [RegisterRequest.OneTimePrekeyDTO]
        public var device: [String: String]
        public init(identityKey: String, identitySignKey: String, identityKeySig: String,
                    signedPrekey: RegisterRequest.SignedPrekeyDTO,
                    oneTimePrekeys: [RegisterRequest.OneTimePrekeyDTO], deviceName: String) {
            self.identityKey = identityKey
            self.identitySignKey = identitySignKey
            self.identityKeySig = identityKeySig
            self.signedPrekey = signedPrekey
            self.oneTimePrekeys = oneTimePrekeys
            self.device = ["name": deviceName]
        }
    }
    public func provisionClaim(_ provisionId: String, provisionToken: String,
                               _ body: ProvisionClaimRequest) async throws -> RegisterResponse {
        try await provisionRequest("api/provision/\(provisionId)/claim",
                                   provisionToken: provisionToken, method: "POST", body: body,
                                   as: RegisterResponse.self)
    }

    public func provisionCancel(_ provisionId: String, provisionToken: String) async throws {
        _ = try await provisionRequest("api/provision/\(provisionId)/cancel",
                                       provisionToken: provisionToken, method: "POST",
                                       body: [String: String](), as: OkResponse.self)
    }

    // MARK: - Restoring from a backup

    /// No provisioning token here: this device has no session at all yet, and
    /// no other device is asked to approve it. The nonce this hands back is
    /// what the claim signs to stand in for that approval.
    public struct RestoreStartResponse: Decodable, Sendable {
        public let restoreId: String
        public let nonce: String
        public let expiresIn: Double
    }
    public func restoreStart(username: String) async throws -> RestoreStartResponse {
        try await post("api/restore/start", body: ["username": username],
                       as: RestoreStartResponse.self)
    }

    public struct RestoreClaimRequest: Encodable {
        public var identityKey: String
        public var identitySignKey: String
        public var identityKeySig: String
        public var signature: String
        public var signedPrekey: RegisterRequest.SignedPrekeyDTO
        public var oneTimePrekeys: [RegisterRequest.OneTimePrekeyDTO]
        public var device: [String: String]
        public init(identityKey: String, identitySignKey: String, identityKeySig: String,
                    signature: String, signedPrekey: RegisterRequest.SignedPrekeyDTO,
                    oneTimePrekeys: [RegisterRequest.OneTimePrekeyDTO], deviceName: String) {
            self.identityKey = identityKey
            self.identitySignKey = identitySignKey
            self.identityKeySig = identityKeySig
            self.signature = signature
            self.signedPrekey = signedPrekey
            self.oneTimePrekeys = oneTimePrekeys
            self.device = ["name": deviceName]
        }
    }
    public func restoreClaim(_ restoreId: String,
                             _ body: RestoreClaimRequest) async throws -> RegisterResponse {
        try await post("api/restore/\(restoreId)/claim", body: body, as: RegisterResponse.self)
    }

    // MARK: - Device sessions

    /// An active session: one of the user's devices whose token has not been revoked.
    public struct SessionDTO: Decodable, Identifiable, Sendable {
        public let deviceId: String
        public let name: String?
        /// Milliseconds: the server writes `devices.created_at` with `Date.now()`, unlike
        /// the other client-visible timestamps, which are in seconds.
        public let createdAt: Double
        public let lastSeen: Double?
        public let hasPushToken: Bool
        /// The device the request came from.
        public let current: Bool

        public var id: String { deviceId }
        public var createdAtSeconds: Double { createdAt / 1000 }
        public var lastSeenSeconds: Double? { lastSeen.map { $0 / 1000 } }
    }
    private struct SessionsResponse: Decodable { let sessions: [SessionDTO] }

    public func sessions() async throws -> [SessionDTO] {
        try await get("api/sessions", as: SessionsResponse.self).sessions
    }

    /// Revokes this device's token; the very next request gets a 401.
    public func logout() async throws {
        _ = try await request("api/logout", method: "POST", jsonBody: [String: String]())
    }

    /// Revokes the token of another device of ours; the server closes its socket with code 4401.
    public func revokeSession(deviceId: String) async throws {
        _ = try await request("api/sessions/\(deviceId)/revoke", method: "POST",
                              jsonBody: [String: String]())
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

    /// A user's device with its identity keys, without the prekey bundle.
    public struct DeviceDTO: Decodable {
        public let userId: String
        public let deviceId: String
        public let identityKey: String
        public let identitySignKey: String
        public let identityKeySig: String
    }
    public struct DevicesResponse: Decodable {
        public let devices: [DeviceDTO]
        /// devices_version per asked user; a user the server does not know is absent
        public let versions: [String: Int]
    }
    /// How many times /api/devices was actually hit; the device cache tests
    /// assert on it.
    public private(set) var devicesRequestCount = 0
    /// Devices of several users in one request; consumes no prekeys.
    public func devices(userIds: [String]) async throws -> DevicesResponse {
        guard !userIds.isEmpty else { return DevicesResponse(devices: [], versions: [:]) }
        devicesRequestCount += 1
        return try await get("api/devices?ids=\(userIds.joined(separator: ","))",
                             as: DevicesResponse.self)
    }

    public struct PrekeyBundleDTO: Decodable {
        public let deviceId: String
        public let identityKey: String
        public let identitySignKey: String
        public let identityKeySig: String
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

    /// Publishes the identity this device encrypts under, so a peer that fetches
    /// the bundle gets the DH key together with the signature binding it.
    public func publishIdentity(identityKey: String, identitySignKey: String,
                                identityKeySig: String) async throws {
        struct Body: Encodable {
            let identityKey: String; let identitySignKey: String; let identityKeySig: String
        }
        _ = try await request("api/identity", method: "POST",
                             jsonBody: Body(identityKey: identityKey,
                                            identitySignKey: identitySignKey,
                                            identityKeySig: identityKeySig))
    }

    /// Replaces this device's published prekey bundle whole: a fresh signed
    /// prekey and a fresh one-time set; the server drops the stale one-times.
    public func republishPrekeys(signedPrekey: RegisterRequest.SignedPrekeyDTO,
                                 oneTimePrekeys: [RegisterRequest.OneTimePrekeyDTO]) async throws {
        struct Body: Encodable {
            let signedPrekey: RegisterRequest.SignedPrekeyDTO
            let oneTimePrekeys: [RegisterRequest.OneTimePrekeyDTO]
        }
        _ = try await request("api/prekeys/republish", method: "POST",
                              jsonBody: Body(signedPrekey: signedPrekey, oneTimePrekeys: oneTimePrekeys))
    }

    public func uploadPrekeys(_ keys: [RegisterRequest.OneTimePrekeyDTO]) async throws {
        struct Body: Encodable { let oneTimePrekeys: [RegisterRequest.OneTimePrekeyDTO] }
        _ = try await request("api/prekeys", method: "POST", jsonBody: Body(oneTimePrekeys: keys))
    }

    private struct PrekeyCountResponse: Decodable { let count: Int }
    /// How many of our own one-time prekeys are left on the server.
    public func prekeyCount() async throws -> Int {
        try await get("api/prekeys/count", as: PrekeyCountResponse.self).count
    }

    // MARK: - Chats

    public struct CreateChatResponse: Decodable {
        public let chatId: String
        /// True when the chat was already there and the call only reopened it.
        public let existed: Bool?
    }
    public func createChat(kind: String, memberIds: [String], title: String?) async throws -> String {
        try await createChatDetailed(kind: kind, memberIds: memberIds, title: title).chatId
    }
    public func createChatDetailed(kind: String, memberIds: [String],
                                   title: String?) async throws -> CreateChatResponse {
        struct Body: Encodable { let kind: String; let memberIds: [String]; let title: String? }
        return try await post("api/chats", body: Body(kind: kind, memberIds: memberIds, title: title),
                              as: CreateChatResponse.self)
    }

    public struct ChatsSnapshot: Decodable {
        public struct Entry: Decodable {
            public let flags: Flags
            public let state: ChatStateDTO
            public struct Flags: Decodable {
                public let pinned: Bool
                public let muted: Bool
                public let mutedUntil: Double?
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

    /// Says the messages reached this device. The socket carries the same thing
    /// as a `recv` frame; this is the door for the notification extension, which
    /// writes a message from a push and has no connection of its own.
    public func markDelivered(_ chatId: String, seqs: [Int]) async throws {
        struct Body: Encodable { let seqs: [Int] }
        _ = try await request("api/chats/\(chatId)/recv", method: "POST", jsonBody: Body(seqs: seqs))
    }
    public func acceptChat(_ chatId: String) async throws {
        _ = try await request("api/chats/\(chatId)/accept", method: "POST", jsonBody: [String: String]())
    }
    /// Takes the chat off this user's list. A group is left, so the others stop
    /// seeing the member; a direct chat is only forgotten here and the peer
    /// keeps his own copy.
    public func deleteChat(_ chatId: String) async throws {
        _ = try await request("api/chats/\(chatId)/delete", method: "POST", jsonBody: [String: String]())
    }
    public func updateMembers(_ chatId: String, add: [String], remove: [String]) async throws {
        struct Body: Encodable { let add: [String]; let remove: [String] }
        _ = try await request("api/chats/\(chatId)/members", method: "POST", jsonBody: Body(add: add, remove: remove))
    }
    public func chatSettings(_ chatId: String, title: String? = nil,
                             avatarId: String? = nil, description: String? = nil,
                             sendPolicy: String? = nil, invitePolicy: String? = nil) async throws {
        struct Body: Encodable {
            let title: String?; let avatarId: String?; let description: String?
            let sendPolicy: String?; let invitePolicy: String?
        }
        _ = try await request("api/chats/\(chatId)/settings", method: "POST",
                              jsonBody: Body(title: title, avatarId: avatarId, description: description,
                                             sendPolicy: sendPolicy, invitePolicy: invitePolicy))
    }
    public func setAdmin(_ chatId: String, userId: String, admin: Bool) async throws {
        struct Body: Encodable { let userId: String; let admin: Bool }
        _ = try await request("api/chats/\(chatId)/admins", method: "POST", jsonBody: Body(userId: userId, admin: admin))
    }
    public func pinMessage(_ chatId: String, seq: Int?, pinned: Bool = true) async throws {
        struct Body: Encodable { let seq: Int?; let pinned: Bool }
        _ = try await request("api/chats/\(chatId)/pin-message", method: "POST",
                              jsonBody: Body(seq: seq, pinned: pinned))
    }
    /// The server ignores `mutedUntil` without `muted`; `muted: true` with no expiry means forever.
    public func setChatFlags(_ chatId: String, pinned: Bool? = nil,
                             muted: Bool? = nil, mutedUntil: Double? = nil,
                             archived: Bool? = nil) async throws {
        struct Body: Encodable {
            let pinned: Bool?; let muted: Bool?; let mutedUntil: Double?; let archived: Bool?
        }
        _ = try await request("api/chats/\(chatId)/flags", method: "POST",
                              jsonBody: Body(pinned: pinned, muted: muted,
                                             mutedUntil: mutedUntil, archived: archived))
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
    /// `progress` hears the sent fraction of the body as it goes up.
    public func uploadMedia(_ data: Data,
                            progress: (@Sendable (Double) -> Void)? = nil) async throws -> MediaUploadResponse {
        var req = URLRequest(url: url(for: "api/media"))
        req.httpMethod = "POST"
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let delegate = progress.map(UploadProgressDelegate.init)
        let (raw, resp) = try await session.upload(for: req, from: data, delegate: delegate)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 400 {
            let err = try? JSONDecoder().decode(ErrBody.self, from: raw)
            throw APIError(code: err?.error ?? "http_\(status)", status: status)
        }
        return try JSONDecoder().decode(MediaUploadResponse.self, from: raw)
    }

    private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
        let progress: @Sendable (Double) -> Void
        init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }
        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                        totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            guard totalBytesExpectedToSend > 0 else { return }
            progress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
        }
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
    /// A shader as the avatar: the document's JSON in the same blob slot; a
    /// peer's app tells it from a picture by the first byte.
    public func uploadShaderAvatar(_ document: ShaderDocument, chatId: String? = nil) async throws -> String {
        let body = try JSONEncoder().encode(document)
        let path = chatId.map { "api/avatar?chatId=\($0)" } ?? "api/avatar"
        let raw = try await request(path, method: "POST", rawBody: body, contentType: "application/json")
        return try JSONDecoder().decode(AvatarResponse.self, from: raw).avatarId
    }
    /// Chat avatar: the same blob path, except the server stores the id in the chat settings
    /// rather than in our own profile. Permissions match /chats/:id/settings.
    public func uploadChatAvatar(chatId: String, jpeg: Data) async throws -> String {
        let raw = try await request("api/avatar?chatId=\(chatId)", method: "POST",
                                    rawBody: jpeg, contentType: "image/jpeg")
        return try JSONDecoder().decode(AvatarResponse.self, from: raw).avatarId
    }
    /// Avatar bytes; the request carries the token.
    public func avatarData(_ avatarId: String) async throws -> Data {
        try await request("api/avatar/\(avatarId)")
    }

    // MARK: - Profile / contacts / misc

    public func updateProfile(displayName: String? = nil, bio: String? = nil, avatarId: String? = nil) async throws {
        struct Body: Encodable { let displayName: String?; let bio: String?; let avatarId: String? }
        _ = try await request("api/profile", method: "POST", jsonBody: Body(displayName: displayName, bio: bio, avatarId: avatarId))
    }

    /// A rename. Throws `APIError("username_taken")` when the handle is
    /// somebody else's; the old one is free the moment this returns.
    public func updateUsername(_ username: String) async throws {
        struct Body: Encodable { let username: String }
        _ = try await request("api/username", method: "POST", jsonBody: Body(username: username))
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

    // MARK: - Privacy

    public struct PrivacyDTO: Codable, Sendable, Equatable {
        public let lastSeen: String
        public let readReceipts: Bool
        public let typing: Bool
    }
    private struct PrivacyResponse: Decodable { let privacy: PrivacyDTO }

    public func privacy() async throws -> PrivacyDTO {
        try await get("api/privacy", as: PrivacyResponse.self).privacy
    }

    /// Any argument left nil keeps the server's current value for it.
    @discardableResult
    public func setPrivacy(
        lastSeen: String? = nil, readReceipts: Bool? = nil, typing: Bool? = nil
    ) async throws -> PrivacyDTO {
        struct Body: Encodable { let lastSeen: String?; let readReceipts: Bool?; let typing: Bool? }
        return try await post("api/privacy",
            body: Body(lastSeen: lastSeen, readReceipts: readReceipts, typing: typing),
            as: PrivacyResponse.self).privacy
    }
}
