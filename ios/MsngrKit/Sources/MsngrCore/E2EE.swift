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
public enum E2EEError: Error {
    /// Identity-ключ получателя сменился: отправка заблокирована, пока
    /// пользователь явно не примет новый ключ (TOFU, как в Signal).
    case identityChanged(userId: String)
}

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

    /// Список устройств собеседника. Бандлы НЕ кэшируются: one-time prekey одноразовый,
    /// повторное использование выданного ключа ломает X3DH у получателя (он его уже удалил).
    private func deviceBundles(userId: String) async throws -> [APIClient.PrekeyBundleDTO] {
        try await api.prekeys(userId: userId).bundles
    }

    private func encryptPairwise(inner: InnerMessage, recipients: [String],
                                 onlyDevices: Set<String>? = nil) async throws -> Envelope {
        let plaintext = try JSONEncoder().encode(inner)
        var boxes: [String: PairwiseBox] = [:]
        var targets = Set(recipients)
        targets.insert(ownUserId) // эхо на свои другие устройства

        for uid in targets {
            let bundles = try await deviceBundles(userId: uid)
            if uid != ownUserId, let first = bundles.first,
               case .changed = try store.checkTrust(userId: uid, identitySigning: first.identitySignKey) {
                throw E2EEError.identityChanged(userId: uid)
            }
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

        // сначала всегда пробуем известные сессии: активную, затем архивные.
        // Сообщение не должно теряться из-за рассинхрона состояний.
        if var existing = try store.loadSession(peerUserId: fromUserId, peerDeviceId: fromDeviceId),
           let plain = try? existing.decrypt(ratchetMsg) {
            try store.saveSession(existing, peerUserId: fromUserId, peerDeviceId: fromDeviceId,
                                  theirIdentityDH: box.ik ?? "")
            return try handleInner(plain, fromUserId: fromUserId, trustIssue: nil)
        }
        var archive = try store.archivedSessions(peerUserId: fromUserId, peerDeviceId: fromDeviceId)
        for i in archive.indices {
            if let plain = try? archive[i].decrypt(ratchetMsg) {
                try store.saveArchivedSessions(archive, peerUserId: fromUserId, peerDeviceId: fromDeviceId)
                return try handleInner(plain, fromUserId: fromUserId, trustIssue: nil)
            }
        }

        if box.type == "pk" {
            // pk не подошёл ни к одной известной сессии → поднимаем новую responder-сессию,
            // а текущую убираем в архив (её ещё могут использовать «догоняющие» сообщения).
            // Так корректно разрешается и одновременная инициация (glare), и рассинхрон.
            try store.archiveCurrentSession(peerUserId: fromUserId, peerDeviceId: fromDeviceId)
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
            }
            // кандидаты: с one-time prekey и без него. Второй вариант спасает, если ключ
            // уже был израсходован (повторная выдача бандла, дубль конверта).
            var candidates: [DoubleRatchetSession] = []
            let identity = try store.identity()
            for otp in [otpPriv, nil] as [Curve25519.KeyAgreement.PrivateKey?] {
                if otpPriv == nil && otp != nil { continue }
                if let x3dh = try? X3DH.respond(our: identity, ourSignedPreKey: spkPriv,
                                                ourOneTimePreKey: otp,
                                                theirIdentityDH: ik, theirEphemeral: ek) {
                    candidates.append(DoubleRatchetSession.initBob(
                        sharedSecret: x3dh.sharedSecret, ourRatchetKey: spkPriv, ad: x3dh.associatedData))
                }
                if otpPriv == nil { break }
            }
            for var candidate in candidates {
                if let plain = try? candidate.decrypt(ratchetMsg) {
                    if let otpId = box.otpId { try store.consumeOneTimePrekey(id: otpId) }
                    try store.saveSession(candidate, peerUserId: fromUserId, peerDeviceId: fromDeviceId,
                                          theirIdentityDH: box.ik ?? "")
                    return try handleInner(plain, fromUserId: fromUserId, trustIssue: trustIssue)
                }
            }
            return .undecryptable(reason: "pk_decrypt_failed")
        }

        // dr-сообщение, к которому не подошла ни активная, ни архивные сессии:
        // ключ может приехать позже (сообщение обогнало свой pk) — вернём retryable-причину
        return .undecryptable(reason: "no_session")
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
