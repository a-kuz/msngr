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

/// Ошибки шифрования исходящих.
public enum E2EEError: Error, Equatable {
    case identityChanged(userId: String) // TOFU: identity-ключ собеседника сменился
    case noDevices(userId: String)       // у получателя нет ни одного устройства
}

/// Итог расшифровки входящего.
public enum DecryptedIncoming {
    case content(ContentPayload)
    /// Sender key chain stored; no content. The chat and chain are carried out
    /// so the recipient can confirm the distribution to its sender.
    case senderKeyDistribution(chatId: String, keyId: String)
    case undecryptable(reason: String)  // нет сессии/ключа — показываем плейсхолдер
    case identityChanged(userId: String, content: ContentPayload?) // TOFU-предупреждение
}

/// E2EE-pipeline: шифрование исходящих (pw / sender keys) и расшифровка входящих.
public final class E2EEManager: @unchecked Sendable {
    let store: IdentityStore
    let api: APIClient
    public let ownUserId: String
    public let ownDeviceId: String

    /// Cross-process exclusion over the crypto state; see `CryptoGate`.
    let gate: CryptoGate
    private let incoming: IncomingDecryptor

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

    // MARK: - Исходящие

    /// direct-чат: pairwise Double Ratchet на каждое устройство получателя (и свои другие).
    public func encryptDirect(content: ContentPayload, toUserId: String) async throws -> Envelope {
        let inner = InnerMessage(content: content)
        return try await encryptPairwise(inner: inner, recipients: [toUserId])
    }

    /// группа: sender key; при необходимости — сначала раздача цепочки pairwise.
    /// skd шлётся отдельным сообщением до контента под возвращённым `skdId`:
    /// повтор той же раздачи гасится серверным дедупом, следующий круг раздачи
    /// (адресат так и не подтвердил) получает свой id и до него доезжает.
    public func encryptGroup(content: ContentPayload, chatId: String,
                             memberIds: [String]) async throws -> (skd: Envelope?, skdId: String?, skm: Envelope) {
        var (state, distributed, attempted) = try store.loadSenderKeyOut(chatId: chatId)
            ?? (SenderKeyState(), Set<String>(), [String: Double]())

        // выяснить все адреса устройств участников (кроме своего устройства)
        let byUser = try await deviceMap(userIds: Set(memberIds))
        var allAddrs: [(userId: String, deviceId: String)] = []
        for uid in memberIds {
            for d in byUser[uid] ?? [] where !(uid == ownUserId && d.deviceId == ownDeviceId) {
                allAddrs.append((uid, d.deviceId))
            }
        }
        // Раздача считается доставленной только по подтверждению получателя:
        // неподтверждённая уходит снова, иначе один потерянный конверт делает
        // нечитаемыми все сообщения этой цепочки.
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

    /// Id раздачи: один и тот же для повтора того же круга, разный для нового
    /// круга и для другого набора адресатов.
    static func skdClientMsgId(chatId: String, keyId: String, recipients: [String], round: Int) -> String {
        let digest = SHA256.hash(data: Data(recipients.sorted().joined(separator: ",").utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        return "skd:\(chatId):\(keyId):\(digest):\(round)"
    }

    /// Получатель подтвердил, что сохранил цепочку: раздавать её ему больше не нужно.
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

    /// Участник не смог прочитать групповое сообщение: раздача ему цепочки
    /// забывается, следующее сообщение в чат раздаст её заново.
    public func forgetSenderKeyDistribution(chatId: String, userId: String) throws {
        guard let (state, distributed, attempted) = try store.loadSenderKeyOut(chatId: chatId) else { return }
        let prefix = userId + "/"
        let keptDistributed = distributed.filter { !$0.hasPrefix(prefix) }
        let keptAttempted = attempted.filter { !$0.key.hasPrefix(prefix) }
        guard keptDistributed.count != distributed.count || keptAttempted.count != attempted.count else { return }
        try store.saveSenderKeyOut(chatId: chatId, state: state,
                                   distributedTo: keptDistributed, attemptedAt: keptAttempted)
    }

    /// Следующее pairwise-сообщение этому собеседнику поднимает сессию заново
    /// (X3DH), а текущая уходит в архив: расшифровать нечитаемое ей всё равно
    /// не удалось, а «догоняющие» сообщения архив ещё откроет.
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

    /// Ротация sender key (при выходе участника из группы).
    public func rotateSenderKey(chatId: String) throws {
        try store.deleteSenderKeyOut(chatId: chatId)
    }

    /// Устройства всех пользователей одним запросом /devices, сгруппированные по userId.
    /// Prekey-бандлы не запрашиваются и one-time prekeys не расходуются.
    private func deviceMap(userIds: Set<String>) async throws -> [String: [APIClient.DeviceDTO]] {
        let all = try await api.devices(userIds: [String](userIds))
        return Dictionary(grouping: all, by: \.userId)
    }

    private func encryptPairwise(inner: InnerMessage, recipients: [String],
                                 onlyDevices: Set<String>? = nil) async throws -> Envelope {
        let plaintext = try JSONEncoder().encode(inner)
        var targets = Set(recipients)
        targets.insert(ownUserId) // эхо на свои другие устройства
        let byUser = try await deviceMap(userIds: targets)

        // получатель без единого устройства — некому шифровать
        for uid in recipients where uid != ownUserId && (byUser[uid] ?? []).isEmpty {
            throw E2EEError.noDevices(userId: uid)
        }
        // TOFU по identity-ключам всех устройств получателя (не только первого)
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
        // полный prekey-бандл (расходует one-time prekey) — только для юзеров,
        // у которых нашлось устройство без установленной сессии
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
                    // сессия помечена на пересборку (по ней не расшифровывалось): текущую
                    // в архив, это сообщение поднимает новую через X3DH
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
                        // существующая сессия → dr, бандл не нужен
                        if !isResetting,
                           var session = try store.loadSession(peerUserId: uid, peerDeviceId: device.deviceId) {
                            let msg = try session.encrypt(plaintext)
                            try store.saveSession(session, peerUserId: uid, peerDeviceId: device.deviceId,
                                                  theirIdentityDH: device.identityKey)
                            boxes[a] = PairwiseBox(type: "dr", c: try JSONEncoder().encode(msg).base64EncodedString())
                            continue
                        }
                        // новой сессии нужен X3DH
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

    /// X3DH-инициация новой сессии по полному prekey-бандлу устройства.
    private func newSessionBox(plaintext: Data, userId: String,
                               bundle: APIClient.PrekeyBundleDTO) throws -> PairwiseBox? {
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

    /// Opening an envelope belongs to `IncomingDecryptor`: it needs the device's
    /// keys and no network, which is what lets the notification service
    /// extension do it too.
    public func decrypt(envelopeJSON: JSONValue, chatId: String,
                        fromUserId: String, fromDeviceId: String) throws -> DecryptedIncoming {
        try incoming.decrypt(envelopeJSON: envelopeJSON, chatId: chatId,
                             fromUserId: fromUserId, fromDeviceId: fromDeviceId)
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
