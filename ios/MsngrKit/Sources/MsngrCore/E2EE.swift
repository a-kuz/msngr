import Foundation
import CryptoKit
import MsngrCrypto

/// Payload inside a pairwise message: either content or a sender key distribution.
public struct InnerMessage: Codable {
    public var type: String            // "content" | "skd"
    public var content: ContentPayload?
    public var skd: SenderKeyDistribution?
    /// The chat this message belongs to, named inside the sealed box: for
    /// content, the chat it was sent in, and for a distribution, the chat the
    /// chain belongs to. The envelope's own chat comes from the server, so a
    /// receiver has this to check it against.
    public var chatId: String?

    public init(content: ContentPayload, chatId: String) {
        self.type = "content"
        self.content = content
        self.chatId = chatId
    }
    public init(skd: SenderKeyDistribution, chatId: String) {
        self.type = "skd"
        self.skd = skd
        self.chatId = chatId
    }
}

/// Failures while encrypting an outgoing message.
public enum E2EEError: Error, Equatable {
    case identityChanged(userId: String) // TOFU: the peer's identity key changed
    case noDevices(userId: String)       // the recipient has no devices at all
}

/// Result of opening an incoming envelope.
public enum DecryptedIncoming {
    case content(ContentPayload)
    /// Sender key chain stored; no content. The chat and chain are carried out
    /// so the recipient can confirm the distribution to its sender.
    case senderKeyDistribution(chatId: String, keyId: String)
    case undecryptable(reason: String)  // no session or key: a placeholder is shown
    case identityChanged(userId: String, content: ContentPayload?) // TOFU warning
}

/// E2EE pipeline: encrypts outgoing messages (pairwise or sender key) and opens incoming ones.
public final class E2EEManager: @unchecked Sendable {
    let store: IdentityStore
    let api: APIClient
    public let ownUserId: String
    public let ownDeviceId: String

    /// Cross-process exclusion over the crypto state; see `CryptoGate`.
    let gate: CryptoGate
    private let incoming: IncomingDecryptor

    /// Device lists already read from the server, by userId. A send reads from
    /// here instead of hitting /api/devices; an entry is dropped by the
    /// `devices` frame and the whole cache on reconnect, since a frame sent
    /// while the socket was down is gone. In-memory only: the extension never
    /// encrypts, and a fresh process starts empty.
    private var deviceCache: [String: [APIClient.DeviceDTO]] = [:]
    private let deviceCacheLock = NSLock()

    public init(store: IdentityStore, api: APIClient, ownUserId: String, ownDeviceId: String,
                gate: CryptoGate = CryptoGate(url: nil)) {
        self.store = store
        self.api = api
        self.ownUserId = ownUserId
        self.ownDeviceId = ownDeviceId
        self.gate = gate
        self.incoming = IncomingDecryptor(store: store, ownUserId: ownUserId,
                                          ownDeviceId: ownDeviceId, gate: gate)
    }

    private func addr(_ userId: String, _ deviceId: String) -> String { "\(userId)/\(deviceId)" }

    // MARK: - Outgoing

    /// Direct chat: a pairwise Double Ratchet message per recipient device, and per own other device.
    public func encryptDirect(content: ContentPayload, chatId: String,
                              toUserId: String) async throws -> Envelope {
        let inner = InnerMessage(content: content, chatId: chatId)
        return try await encryptPairwise(inner: inner, recipients: [toUserId])
    }

    /// Group: sender key, preceded where needed by a pairwise distribution of the chain.
    /// The skd goes as its own message ahead of the content under the returned `skdId`:
    /// repeating the same distribution is swallowed by the server's dedup, while the
    /// next round (the recipient still has not confirmed) gets its own id and gets through.
    public func encryptGroup(content: ContentPayload, chatId: String,
                             memberIds: [String]) async throws -> (skd: Envelope?, skdId: String?, skm: Envelope) {
        var (state, distributed, attempted) = try store.loadSenderKeyOut(chatId: chatId)
            ?? (SenderKeyState(), Set<String>(), [String: Double]())

        // every member device address except this device
        let byUser = try await deviceMap(userIds: Set(memberIds))
        var allAddrs: [(userId: String, deviceId: String)] = []
        for uid in memberIds {
            for d in byUser[uid] ?? [] where !(uid == ownUserId && d.deviceId == ownDeviceId) {
                allAddrs.append((uid, d.deviceId))
            }
        }
        // A distribution counts as delivered only once the recipient confirms it.
        // An unconfirmed one is sent again: otherwise a single lost envelope leaves
        // every message of that chain unreadable.
        let now = Date().timeIntervalSince1970
        let missing = allAddrs.filter {
            let a = addr($0.userId, $0.deviceId)
            guard !distributed.contains(a) else { return false }
            return now - (attempted[a] ?? 0) >= MessageRepair.redistributeAfter
        }

        var skdEnvelope: Envelope?
        var skdId: String?
        if !missing.isEmpty {
            let dist = try state.distribution
            let inner = InnerMessage(skd: dist, chatId: chatId)
            skdEnvelope = try await encryptPairwise(inner: inner,
                                                    recipients: [String](Set(missing.map(\.userId))),
                                                    onlyDevices: Set(missing.map { addr($0.userId, $0.deviceId) }))
            skdId = Self.skdClientMsgId(chatId: chatId, keyId: state.keyId,
                                        recipients: missing.map { addr($0.userId, $0.deviceId) },
                                        round: Int(now))
            for m in missing { attempted[addr(m.userId, m.deviceId)] = now }
        }

        let plaintext = try JSONEncoder().encode(content)
        let skm = try state.encrypt(plaintext)
        try store.saveSenderKeyOut(chatId: chatId, state: state,
                                   distributedTo: distributed, attemptedAt: attempted)

        var env = Envelope(mode: "skm")
        env.c = skm.ciphertext.base64EncodedString()
        env.keyId = skm.keyId
        env.iteration = skm.iteration
        env.sig = skm.signature.base64EncodedString()
        return (skdEnvelope, skdId, env)
    }

    /// Distribution id: the same when a round is repeated, different for a new round
    /// and for a different set of recipients.
    static func skdClientMsgId(chatId: String, keyId: String, recipients: [String], round: Int) -> String {
        let digest = SHA256.hash(data: Data(recipients.sorted().joined(separator: ",").utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        return "skd:\(chatId):\(keyId):\(digest):\(round)"
    }

    /// The recipient confirmed it stored the chain, so it need not be handed out again.
    public func confirmSenderKey(chatId: String, keyId: String, userId: String, deviceId: String) throws {
        guard let (state, distributed, attempted) = try store.loadSenderKeyOut(chatId: chatId),
              state.keyId == keyId else { return }
        let a = addr(userId, deviceId)
        guard !distributed.contains(a) else { return }
        var confirmed = distributed
        var pending = attempted
        confirmed.insert(a)
        pending.removeValue(forKey: a)
        try store.saveSenderKeyOut(chatId: chatId, state: state,
                                   distributedTo: confirmed, attemptedAt: pending)
    }

    /// A member could not read a group message: their distribution is forgotten, so the
    /// next message to the chat hands the chain out to them again.
    public func forgetSenderKeyDistribution(chatId: String, userId: String) throws {
        guard let (state, distributed, attempted) = try store.loadSenderKeyOut(chatId: chatId) else { return }
        let prefix = userId + "/"
        let keptDistributed = distributed.filter { !$0.hasPrefix(prefix) }
        let keptAttempted = attempted.filter { !$0.key.hasPrefix(prefix) }
        guard keptDistributed.count != distributed.count || keptAttempted.count != attempted.count else { return }
        try store.saveSenderKeyOut(chatId: chatId, state: state,
                                   distributedTo: keptDistributed, attemptedAt: keptAttempted)
    }

    /// The next pairwise message to this peer builds a fresh session over X3DH and puts
    /// the current one in the archive: it failed to open the unreadable message anyway,
    /// and the archive can still open messages that arrive late under it.
    public func resetPairwiseSession(with userId: String) throws {
        try store.requestSessionReset(peerUserId: userId)
    }

    /// More one-time prekeys, private halves stored. The extension spends them
    /// on the other side — a prekey envelope that arrives by push consumes one
    /// — so the two of them meet over this blob.
    public func moreOneTimePrekeys(count: Int) throws -> [OneTimePreKey] {
        try gate.withLock { _ in try store.generateMoreOneTime(count: count) }
    }

    /// The user accepted a peer's new identity key. The extension writes the
    /// same row when it opens a prekey envelope.
    public func acceptChangedIdentity(userId: String) throws {
        try gate.withLock { _ in try store.acceptChangedKey(userId: userId) }
    }

    /// Rotates the sender key, e.g. after a member leaves the group.
    public func rotateSenderKey(chatId: String) throws {
        try store.deleteSenderKeyOut(chatId: chatId)
    }

    /// A device of ours is no longer ours: every group chain it was handed is
    /// dropped, so the next group message runs on one it never held. The server
    /// stops delivering to a revoked device, but a chain it already has would
    /// still open a copy that reached it another way.
    public func rotateAllSenderKeys() throws {
        try store.deleteAllSenderKeyOut()
    }

    /// The `devices` frame said this user's device set changed: the next send
    /// re-reads their list from the server.
    public func invalidateDeviceCache(userId: String) {
        deviceCacheLock.lock()
        defer { deviceCacheLock.unlock() }
        deviceCache.removeValue(forKey: userId)
    }

    /// The socket was down, so any `devices` frame from that time is lost:
    /// every list is re-read.
    public func invalidateDeviceCache() {
        deviceCacheLock.lock()
        defer { deviceCacheLock.unlock() }
        deviceCache.removeAll()
    }

    /// Test hook: what the cache holds for a user, nil when it holds nothing.
    func cachedDevices(userId: String) -> [APIClient.DeviceDTO]? {
        deviceCacheLock.lock()
        defer { deviceCacheLock.unlock() }
        return deviceCache[userId]
    }

    /// Devices of every user, grouped by userId: cached lists as they are, the
    /// rest in a single /devices call. This asks for no prekey bundles, so it
    /// spends no one-time prekeys.
    private func deviceMap(userIds: Set<String>) async throws -> [String: [APIClient.DeviceDTO]] {
        var result: [String: [APIClient.DeviceDTO]] = [:]
        var missing: [String] = []
        deviceCacheLock.lock()
        for uid in userIds {
            if let cached = deviceCache[uid] { result[uid] = cached } else { missing.append(uid) }
        }
        deviceCacheLock.unlock()
        guard !missing.isEmpty else { return result }
        let fetched = Dictionary(grouping: try await api.devices(userIds: missing), by: \.userId)
        deviceCacheLock.lock()
        for uid in missing {
            let devices = fetched[uid] ?? []
            deviceCache[uid] = devices
            result[uid] = devices
        }
        deviceCacheLock.unlock()
        return result
    }

    private func encryptPairwise(inner: InnerMessage, recipients: [String],
                                 onlyDevices: Set<String>? = nil) async throws -> Envelope {
        let plaintext = try JSONEncoder().encode(inner)
        var targets = Set(recipients)
        targets.insert(ownUserId) // echo to this user's other devices
        let byUser = try await deviceMap(userIds: targets)

        // a recipient with no devices at all: there is nothing to encrypt to
        for uid in recipients where uid != ownUserId && (byUser[uid] ?? []).isEmpty {
            throw E2EEError.noDevices(userId: uid)
        }
        // TOFU over the identity keys of every recipient device, not just the first one
        try gate.withLock { _ in
            for uid in targets where uid != ownUserId {
                for d in byUser[uid] ?? [] {
                    if case .changed = try store.checkTrust(userId: uid, identitySigning: d.identitySignKey) {
                        throw E2EEError.identityChanged(userId: uid)
                    }
                }
            }
        }

        var boxes: [String: PairwiseBox] = [:]
        // the full prekey bundle (which spends a one-time prekey) is fetched only for
        // users that turned out to have a device with no session yet
        var bundlesByUser: [String: [APIClient.PrekeyBundleDTO]] = [:]
        /// Sessions marked for a rebuild, consumed once and remembered: a second
        /// pass must not read the mark as absent and encrypt to the old session.
        var resetting: [String: Bool] = [:]
        var archived: Set<String> = []

        // The pass over the sessions runs behind the gate, so a ratchet step is
        // never interleaved with the extension's. Asking the server for a prekey
        // bundle cannot happen there — a lock is not held across a request — so
        // the pass reports the users whose bundles it lacks, they are fetched,
        // and the pass runs again for what is left.
        for _ in 0..<2 {
            let needBundles = try gate.withLock { _ -> Set<String> in
                var needed: Set<String> = []
                for uid in targets {
                    // the session is marked for a rebuild (nothing decrypted under it):
                    // the current one goes to the archive, this message starts a new
                    // one over X3DH
                    let isResetting = resetting[uid]
                        ?? ((try? store.consumeSessionReset(peerUserId: uid)) ?? false)
                    resetting[uid] = isResetting
                    for device in byUser[uid] ?? [] {
                        if uid == ownUserId && device.deviceId == ownDeviceId { continue }
                        let a = addr(uid, device.deviceId)
                        if boxes[a] != nil { continue }
                        if let onlyDevices, !onlyDevices.contains(a), uid != ownUserId { continue }
                        if isResetting, archived.insert(a).inserted {
                            try? store.archiveCurrentSession(peerUserId: uid, peerDeviceId: device.deviceId)
                        }
                        // an existing session encrypts as dr and needs no bundle
                        if !isResetting,
                           var session = try store.loadSession(peerUserId: uid, peerDeviceId: device.deviceId) {
                            let msg = try session.encrypt(plaintext)
                            try store.saveSession(session, peerUserId: uid, peerDeviceId: device.deviceId)
                            boxes[a] = PairwiseBox(type: "dr", c: try JSONEncoder().encode(msg).base64EncodedString())
                            continue
                        }
                        // a new session needs X3DH
                        guard let bundle = bundlesByUser[uid]?.first(where: { $0.deviceId == device.deviceId })
                        else {
                            if bundlesByUser[uid] == nil { needed.insert(uid) }
                            continue
                        }
                        if let box = try newSessionBox(plaintext: plaintext, userId: uid, bundle: bundle) {
                            boxes[a] = box
                        }
                    }
                }
                return needed
            }
            if needBundles.isEmpty { break }
            for uid in needBundles {
                bundlesByUser[uid] = try await api.prekeys(userId: uid).bundles
            }
        }
        var env = Envelope(mode: "pw")
        env.msgs = boxes
        return env
    }

    /// Starts a new session over X3DH from a device's full prekey bundle.
    private func newSessionBox(plaintext: Data, userId: String,
                               bundle: APIClient.PrekeyBundleDTO) throws -> PairwiseBox? {
        guard let ikDH = Data(base64urlEncoded: bundle.identityKey),
              let ikSign = Data(base64urlEncoded: bundle.identitySignKey),
              let ikSig = Data(base64urlEncoded: bundle.identityKeySig),
              let spk = Data(base64urlEncoded: bundle.signedPrekey.key),
              let spkSig = Data(base64urlEncoded: bundle.signedPrekey.sig) else { return nil }

        let pkBundle = PreKeyBundle(
            identity: IdentityPublicKeys(dh: ikDH, signing: ikSign, dhSignature: ikSig),
            signedPreKeyId: bundle.signedPrekey.id,
            signedPreKey: spk,
            signedPreKeySignature: spkSig,
            oneTimePreKeyId: bundle.oneTimePrekey?.id,
            oneTimePreKey: bundle.oneTimePrekey.flatMap { Data(base64urlEncoded: $0.key) }
        )
        let our = try store.identity()
        let x3dh = try X3DH.initiate(our: our, their: pkBundle)
        var session = try DoubleRatchetSession.initAlice(
            sharedSecret: x3dh.sharedSecret, theirRatchetPub: spk, ad: x3dh.associatedData)
        let msg = try session.encrypt(plaintext)
        try store.saveSession(session, peerUserId: userId, peerDeviceId: bundle.deviceId)

        var box = PairwiseBox(type: "pk", c: try JSONEncoder().encode(msg).base64EncodedString())
        box.ik = our.dh.publicKey.rawRepresentation.base64urlEncodedString()
        box.isk = our.signing.publicKey.rawRepresentation.base64urlEncodedString()
        box.iksig = try our.dhSignature.base64urlEncodedString()
        box.ek = x3dh.ephemeralPublic.base64urlEncodedString()
        box.spkId = bundle.signedPrekey.id
        box.otpId = bundle.oneTimePrekey?.id
        return box
    }

    // MARK: - Incoming

    /// Opening an envelope belongs to `IncomingDecryptor`: it needs the device's
    /// keys and no network, which is what lets the notification service
    /// extension do it too.
    public func decrypt(envelopeJSON: JSONValue, chatId: String,
                        fromUserId: String, fromDeviceId: String) throws -> DecryptedIncoming {
        try incoming.decrypt(envelopeJSON: envelopeJSON, chatId: chatId,
                             fromUserId: fromUserId, fromDeviceId: fromDeviceId)
    }

}

