import Foundation
import CryptoKit
import MsngrCrypto

/// Внутреннее содержимое pairwise-сообщения: либо контент, либо раздача sender key.
public struct InnerMessage: Codable {
    public var type: String            // "content" | "skd"
    public var content: ContentPayload?
    public var skd: SenderKeyDistribution?
    public var chatId: String?         // для skd: к какому чату цепочка

    public init(content: ContentPayload) {
        self.type = "content"
        self.content = content
    }
    public init(skd: SenderKeyDistribution, chatId: String) {
        self.type = "skd"
        self.skd = skd
        self.chatId = chatId
    }
}

/// Итог расшифровки входящего.
public enum DecryptedIncoming {
    case content(ContentPayload)
    case senderKeyDistribution          // состояние сохранено, контента нет
    case undecryptable(reason: String)  // нет сессии/ключа — показываем плейсхолдер
    case identityChanged(userId: String, content: ContentPayload?) // TOFU-предупреждение
}

/// E2EE-pipeline: шифрование исходящих (pw / sender keys) и расшифровка входящих.
public final class E2EEManager: @unchecked Sendable {
    let store: IdentityStore
    let api: APIClient
    public let ownUserId: String
    public let ownDeviceId: String

    public init(store: IdentityStore, api: APIClient, ownUserId: String, ownDeviceId: String) {
        self.store = store
        self.api = api
        self.ownUserId = ownUserId
        self.ownDeviceId = ownDeviceId
    }

    private func addr(_ userId: String, _ deviceId: String) -> String { "\(userId)/\(deviceId)" }

    // MARK: - Исходящие

    /// direct-чат: pairwise Double Ratchet на каждое устройство получателя (и свои другие).
    public func encryptDirect(content: ContentPayload, toUserId: String) async throws -> Envelope {
        let inner = InnerMessage(content: content)
        return try await encryptPairwise(inner: inner, recipients: [toUserId])
    }

    /// группа: sender key; при необходимости — сначала раздача цепочки pairwise.
    /// Возвращает (skdEnvelope?, skmEnvelope): skd шлётся отдельным сообщением до контента.
    public func encryptGroup(content: ContentPayload, chatId: String,
                             memberIds: [String]) async throws -> (skd: Envelope?, skm: Envelope) {
        var (state, distributed) = try store.loadSenderKeyOut(chatId: chatId)
            ?? (SenderKeyState(), Set<String>())

        // выяснить все адреса устройств участников (кроме своего устройства)
        var allAddrs: [(userId: String, deviceId: String)] = []
        for uid in memberIds {
            let bundles = try await deviceBundles(userId: uid)
            for b in bundles where !(uid == ownUserId && b.deviceId == ownDeviceId) {
                allAddrs.append((uid, b.deviceId))
            }
        }
        let missing = allAddrs.filter { !distributed.contains(addr($0.userId, $0.deviceId)) }

        var skdEnvelope: Envelope?
        if !missing.isEmpty {
            let dist = try state.distribution
            let inner = InnerMessage(skd: dist, chatId: chatId)
            skdEnvelope = try await encryptPairwise(inner: inner,
                                                    recipients: [String](Set(missing.map(\.userId))),
                                                    onlyDevices: Set(missing.map { addr($0.userId, $0.deviceId) }))
            for m in missing { distributed.insert(addr(m.userId, m.deviceId)) }
        }

        let plaintext = try JSONEncoder().encode(content)
        let skm = try state.encrypt(plaintext)
        try store.saveSenderKeyOut(chatId: chatId, state: state, distributedTo: distributed)

        var env = Envelope(mode: "skm")
        env.c = skm.ciphertext.base64EncodedString()
        env.keyId = skm.keyId
        env.iteration = skm.iteration
        env.sig = skm.signature.base64EncodedString()
        return (skdEnvelope, env)
    }

    /// Ротация sender key (при выходе участника из группы).
    public func rotateSenderKey(chatId: String) throws {
        try store.deleteSenderKeyOut(chatId: chatId)
    }

    private struct CachedBundles {
        var bundles: [APIClient.PrekeyBundleDTO]
        var at: Date
    }
    private var bundleCache: [String: CachedBundles] = [:]
    private let cacheLock = NSLock()

    private func cachedBundles(_ userId: String) -> [APIClient.PrekeyBundleDTO]? {
        cacheLock.withLock {
            guard let c = bundleCache[userId], Date().timeIntervalSince(c.at) < 300 else { return nil }
            return c.bundles
        }
    }

    private func storeBundles(_ userId: String, _ bundles: [APIClient.PrekeyBundleDTO]) {
        cacheLock.withLock { bundleCache[userId] = CachedBundles(bundles: bundles, at: Date()) }
    }

    private func deviceBundles(userId: String) async throws -> [APIClient.PrekeyBundleDTO] {
        if let cached = cachedBundles(userId) { return cached }
        let res = try await api.prekeys(userId: userId)
        storeBundles(userId, res.bundles)
        return res.bundles
    }

    private func encryptPairwise(inner: InnerMessage, recipients: [String],
                                 onlyDevices: Set<String>? = nil) async throws -> Envelope {
        let plaintext = try JSONEncoder().encode(inner)
        var boxes: [String: PairwiseBox] = [:]
        var targets = Set(recipients)
        targets.insert(ownUserId) // эхо на свои другие устройства

        for uid in targets {
            let bundles = try await deviceBundles(userId: uid)
            for bundle in bundles {
                if uid == ownUserId && bundle.deviceId == ownDeviceId { continue }
                let a = addr(uid, bundle.deviceId)
                if let onlyDevices, !onlyDevices.contains(a), uid != ownUserId { continue }
                if let box = try await encryptToDevice(plaintext: plaintext, userId: uid, bundle: bundle) {
                    boxes[a] = box
                }
            }
        }
        var env = Envelope(mode: "pw")
        env.msgs = boxes
        return env
    }

    private func encryptToDevice(plaintext: Data, userId: String,
                                 bundle: APIClient.PrekeyBundleDTO) async throws -> PairwiseBox? {
        // существующая сессия → dr
        if var session = try store.loadSession(peerUserId: userId, peerDeviceId: bundle.deviceId) {
            let msg = try session.encrypt(plaintext)
            try store.saveSession(session, peerUserId: userId, peerDeviceId: bundle.deviceId,
                                  theirIdentityDH: bundle.identityKey)
            return PairwiseBox(type: "dr", c: try JSONEncoder().encode(msg).base64EncodedString())
        }
        // новой сессии нужен X3DH
        guard let ikDH = Data(base64urlEncoded: bundle.identityKey),
              let ikSign = Data(base64urlEncoded: bundle.identitySignKey),
              let spk = Data(base64urlEncoded: bundle.signedPrekey.key),
              let spkSig = Data(base64urlEncoded: bundle.signedPrekey.sig) else { return nil }

        let pkBundle = PreKeyBundle(
            identity: IdentityPublicKeys(dh: ikDH, signing: ikSign),
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
        try store.saveSession(session, peerUserId: userId, peerDeviceId: bundle.deviceId,
                              theirIdentityDH: bundle.identityKey)

        var box = PairwiseBox(type: "pk", c: try JSONEncoder().encode(msg).base64EncodedString())
        box.ik = our.dh.publicKey.rawRepresentation.base64urlEncodedString()
        box.isk = our.signing.publicKey.rawRepresentation.base64urlEncodedString()
        box.ek = x3dh.ephemeralPublic.base64urlEncodedString()
        box.spkId = bundle.signedPrekey.id
        box.otpId = bundle.oneTimePrekey?.id
        return box
    }

    // MARK: - Входящие

    public func decrypt(envelopeJSON: JSONValue, chatId: String,
                        fromUserId: String, fromDeviceId: String) throws -> DecryptedIncoming {
        let env: Envelope
        do { env = try envelopeJSON.decoded(Envelope.self) }
        catch { return .undecryptable(reason: "bad_envelope") }

        switch env.mode {
        case "pw":
            guard let box = env.msgs?[addr(ownUserId, ownDeviceId)] else {
                return .undecryptable(reason: "not_addressed")
            }
            return try decryptPairwise(box: box, chatId: chatId,
                                       fromUserId: fromUserId, fromDeviceId: fromDeviceId)
        case "skm":
            guard let cB64 = env.c, let c = Data(base64Encoded: cB64),
                  let keyId = env.keyId, let iteration = env.iteration,
                  let sigB64 = env.sig, let sig = Data(base64Encoded: sigB64) else {
                return .undecryptable(reason: "bad_skm")
            }
            guard var receiver = try store.loadSenderKeyIn(chatId: chatId, senderUserId: fromUserId, keyId: keyId) else {
                return .undecryptable(reason: "no_sender_key")
            }
            let msg = SenderKeyMessage(keyId: keyId, iteration: iteration, ciphertext: c, signature: sig)
            let plaintext = try receiver.decrypt(msg)
            try store.saveSenderKeyIn(chatId: chatId, senderUserId: fromUserId, keyId: keyId, state: receiver)
            let content = try JSONDecoder().decode(ContentPayload.self, from: plaintext)
            return .content(content)
        default:
            return .undecryptable(reason: "unknown_mode")
        }
    }

    private func decryptPairwise(box: PairwiseBox, chatId: String,
                                 fromUserId: String, fromDeviceId: String) throws -> DecryptedIncoming {
        guard let msgData = Data(base64Encoded: box.c),
              let ratchetMsg = try? JSONDecoder().decode(RatchetMessage.self, from: msgData) else {
            return .undecryptable(reason: "bad_box")
        }

        var trustIssue: String?
        var session: DoubleRatchetSession

        if box.type == "pk" {
            let existingSession = try store.loadSession(peerUserId: fromUserId, peerDeviceId: fromDeviceId)
            // повторное pk в рамках живой сессии — сначала пробуем её
            if var existing = existingSession, let plain = try? existing.decrypt(ratchetMsg) {
                try store.saveSession(existing, peerUserId: fromUserId, peerDeviceId: fromDeviceId,
                                      theirIdentityDH: box.ik ?? "")
                return try handleInner(plain, fromUserId: fromUserId, trustIssue: nil)
            }
            // сессия существует, но pk ею не расшифровался
            if let existing = existingSession {
                // устоявшаяся сессия → это replay/подмена начального конверта: игнорируем,
                // не сбрасывая ratchet (защита от session-reset)
                if existing.hasReceived {
                    return .undecryptable(reason: "stale_pk_ignored")
                }
                // свежая наша initiator-сессия + встречный pk = glare (обе стороны
                // инициировали). Детерминированный тай-брейкер по identity-ключу:
                // сторона с меньшим ключом оставляет свою сессию, другая принимает pk.
                if let theirIk = box.ik.flatMap({ Data(base64urlEncoded: $0) }) {
                    let ourIk = try store.identity().dh.publicKey.rawRepresentation
                    if ourIk.lexicographicallyPrecedes(theirIk) {
                        // мы «Alice» — оставляем свою сессию, встречный pk отбрасываем
                        return .undecryptable(reason: "glare_kept_ours")
                    }
                    // мы «Bob» — принимаем pk собеседника (перезаписываем свою ниже)
                }
            }
            guard let ikB64 = box.ik, let ik = Data(base64urlEncoded: ikB64),
                  let ekB64 = box.ek, let ek = Data(base64urlEncoded: ekB64),
                  let spkId = box.spkId,
                  let spkPriv = try store.signedPrekey(id: spkId) else {
                return .undecryptable(reason: "bad_pk")
            }
            if let iskB64 = box.isk {
                let trust = try store.checkTrust(userId: fromUserId, identitySigning: iskB64)
                if case .changed = trust { trustIssue = iskB64 }
            }
            var otpPriv: Curve25519.KeyAgreement.PrivateKey?
            if let otpId = box.otpId {
                otpPriv = try store.oneTimePrekey(id: otpId)
                try store.consumeOneTimePrekey(id: otpId)
            }
            let x3dh = try X3DH.respond(our: try store.identity(), ourSignedPreKey: spkPriv,
                                        ourOneTimePreKey: otpPriv,
                                        theirIdentityDH: ik, theirEphemeral: ek)
            session = DoubleRatchetSession.initBob(sharedSecret: x3dh.sharedSecret,
                                                   ourRatchetKey: spkPriv, ad: x3dh.associatedData)
        } else {
            guard let existing = try store.loadSession(peerUserId: fromUserId, peerDeviceId: fromDeviceId) else {
                return .undecryptable(reason: "no_session")
            }
            session = existing
        }

        let plaintext: Data
        do { plaintext = try session.decrypt(ratchetMsg) }
        catch { return .undecryptable(reason: "decrypt_failed") }
        try store.saveSession(session, peerUserId: fromUserId, peerDeviceId: fromDeviceId,
                              theirIdentityDH: box.ik ?? "")
        return try handleInner(plaintext, fromUserId: fromUserId, trustIssue: trustIssue)
    }

    private func handleInner(_ plaintext: Data, fromUserId: String, trustIssue: String?) throws -> DecryptedIncoming {
        let inner = try JSONDecoder().decode(InnerMessage.self, from: plaintext)
        if inner.type == "skd", let skd = inner.skd, let chatId = inner.chatId {
            let receiver = SenderKeyReceiver(distribution: skd)
            try store.saveSenderKeyIn(chatId: chatId, senderUserId: fromUserId,
                                      keyId: skd.keyId, state: receiver)
            return .senderKeyDistribution
        }
        guard let content = inner.content else { return .undecryptable(reason: "empty_inner") }
        if trustIssue != nil {
            return .identityChanged(userId: fromUserId, content: content)
        }
        return .content(content)
    }
}

// MARK: - base64url helpers

extension Data {
    public init?(base64urlEncoded s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
    public func base64urlEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
