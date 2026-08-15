import CryptoKit
import Foundation

/// Double Ratchet (Signal spec): DH-рэтчет + симметричные цепочки,
/// поддержка out-of-order через skipped message keys.
public struct RatchetHeader: Codable, Sendable, Equatable {
    public let dhPub: Data   // текущий DH-pub отправителя
    public let pn: UInt32    // длина предыдущей отправной цепочки
    public let n: UInt32     // номер сообщения в текущей цепочке
}

public struct RatchetMessage: Codable, Sendable {
    public let header: RatchetHeader
    public let ciphertext: Data
}

public struct DoubleRatchetSession: Codable, Sendable {
    var rootKey: Data
    var dhSelfPriv: Data
    var dhRemotePub: Data?
    var sendChainKey: Data?
    var recvChainKey: Data?
    var sendN: UInt32 = 0
    var recvN: UInt32 = 0
    var prevSendN: UInt32 = 0
    var skipped: [String: Data] = [:] // "\(dhPub.base64)/\(n)" -> messageKey
    public var associatedData: Data

    /// Messages one chain may jump over in a single step, and skipped keys kept
    /// across steps. Sized for a device that comes back after a long silence:
    /// the peer's chain can be thousands of messages ahead, and a window that
    /// ends before it leaves every one of them unreadable. The keys are derived
    /// and held only while messages are actually missing, so the cost is paid in
    /// that case alone.
    static let maxSkip: UInt32 = 5000
    static let maxSkippedStored = 5000

    /// Сессия уже получала входящие (устоялась) — признак того, что повторный
    /// prekey-конверт следует игнорировать (защита от replay/session-reset).
    public var hasReceived: Bool { recvN > 0 || recvChainKey != nil }

    // MARK: - KDF

    private static func kdfRoot(_ rootKey: Data, dhOut: SharedSecret) -> (root: Data, chain: Data) {
        let out = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: dhOut.withUnsafeBytes { Data($0) }),
            salt: rootKey,
            info: Data("MsngrRatchet".utf8),
            outputByteCount: 64
        )
        let bytes = out.withUnsafeBytes { Data($0) }
        return (root: bytes.prefix(32), chain: bytes.suffix(32))
    }

    private static func kdfChain(_ chainKey: Data) -> (next: Data, message: Data) {
        let next = HMAC<SHA256>.authenticationCode(for: Data([0x02]), using: SymmetricKey(data: chainKey))
        let msg = HMAC<SHA256>.authenticationCode(for: Data([0x01]), using: SymmetricKey(data: chainKey))
        return (Data(next), Data(msg))
    }

    // MARK: - Init

    /// Алиса (инициатор): знает DH-pub Боба (его signed prekey).
    public static func initAlice(sharedSecret: SymmetricKey, theirRatchetPub: Data, ad: Data) throws -> DoubleRatchetSession {
        let dhSelf = Curve25519.KeyAgreement.PrivateKey()
        let remote = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirRatchetPub)
        let sk = sharedSecret.withUnsafeBytes { Data($0) }
        let dhOut = try dhSelf.sharedSecretFromKeyAgreement(with: remote)
        let (root, chain) = kdfRoot(sk, dhOut: dhOut)
        var s = DoubleRatchetSession(rootKey: root,
                                     dhSelfPriv: dhSelf.rawRepresentation,
                                     dhRemotePub: theirRatchetPub,
                                     associatedData: ad)
        s.sendChainKey = chain
        return s
    }

    /// Боб (ответчик): его ratchet-ключ = signed prekey.
    public static func initBob(sharedSecret: SymmetricKey, ourRatchetKey: Curve25519.KeyAgreement.PrivateKey, ad: Data) -> DoubleRatchetSession {
        let sk = sharedSecret.withUnsafeBytes { Data($0) }
        return DoubleRatchetSession(rootKey: sk,
                                    dhSelfPriv: ourRatchetKey.rawRepresentation,
                                    dhRemotePub: nil,
                                    associatedData: ad)
    }

    // MARK: - Encrypt / Decrypt

    public mutating func encrypt(_ plaintext: Data) throws -> RatchetMessage {
        guard let chainKey = sendChainKey else { throw CryptoError.noSession }
        let (next, msgKey) = Self.kdfChain(chainKey)
        sendChainKey = next
        let selfKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: dhSelfPriv)
        let header = RatchetHeader(dhPub: selfKey.publicKey.rawRepresentation, pn: prevSendN, n: sendN)
        sendN += 1
        let sealed = try ChaChaPoly.seal(plaintext, using: SymmetricKey(data: msgKey),
                                         authenticating: associatedData + headerBytes(header))
        return RatchetMessage(header: header, ciphertext: sealed.combined)
    }

    public mutating func decrypt(_ message: RatchetMessage) throws -> Data {
        // 1. skipped?
        let skipKey = Self.skippedKey(message.header.dhPub, message.header.n)
        if let mk = skipped[skipKey] {
            skipped.removeValue(forKey: skipKey)
            return try open(message, with: mk)
        }
        // 2. новый DH-pub отправителя → DH-рэтчет
        if message.header.dhPub != dhRemotePub {
            try skipRecvKeys(until: message.header.pn) // дочитать старую цепочку
            try dhRatchet(remotePub: message.header.dhPub)
        }
        // 3. пропущенные в текущей цепочке
        try skipRecvKeys(until: message.header.n)
        guard let chainKey = recvChainKey else { throw CryptoError.noSession }
        let (next, msgKey) = Self.kdfChain(chainKey)
        recvChainKey = next
        recvN += 1
        return try open(message, with: msgKey)
    }

    // MARK: - Internals

    private static func skippedKey(_ dhPub: Data, _ n: UInt32) -> String {
        dhPub.base64EncodedString() + "/" + String(n)
    }

    private func headerBytes(_ h: RatchetHeader) -> Data {
        var d = h.dhPub
        withUnsafeBytes(of: h.pn.bigEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: h.n.bigEndian) { d.append(contentsOf: $0) }
        return d
    }

    private func open(_ message: RatchetMessage, with msgKey: Data) throws -> Data {
        do {
            let box = try ChaChaPoly.SealedBox(combined: message.ciphertext)
            return try ChaChaPoly.open(box, using: SymmetricKey(data: msgKey),
                                       authenticating: associatedData + headerBytes(message.header))
        } catch {
            throw CryptoError.decryptionFailed
        }
    }

    private mutating func skipRecvKeys(until n: UInt32) throws {
        guard recvChainKey != nil || n == 0 else { return }
        guard n >= recvN else { return }
        guard n - recvN <= Self.maxSkip else { throw CryptoError.tooManySkipped }
        guard var chainKey = recvChainKey, let remote = dhRemotePub else { return }
        while recvN < n {
            let (next, msgKey) = Self.kdfChain(chainKey)
            skipped[Self.skippedKey(remote, recvN)] = msgKey
            chainKey = next
            recvN += 1
        }
        recvChainKey = chainKey
        // не дать skipped расти бесконечно: вытесняем самые старые по номеру сообщения
        if skipped.count > Self.maxSkippedStored {
            func msgIndex(_ key: String) -> UInt32 {
                UInt32(key.split(separator: "/").last.map(String.init) ?? "") ?? 0
            }
            for key in skipped.keys.sorted(by: { msgIndex($0) < msgIndex($1) })
                .prefix(skipped.count - Self.maxSkippedStored) {
                skipped.removeValue(forKey: key)
            }
        }
    }

    private mutating func dhRatchet(remotePub: Data) throws {
        prevSendN = sendN
        sendN = 0
        recvN = 0
        dhRemotePub = remotePub
        let remote = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePub)

        // recv chain: наш текущий ключ + их новый pub
        let selfKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: dhSelfPriv)
        let recvOut = try selfKey.sharedSecretFromKeyAgreement(with: remote)
        let (root1, recvChain) = Self.kdfRoot(rootKey, dhOut: recvOut)
        rootKey = root1
        recvChainKey = recvChain

        // send chain: наш новый ключ + их новый pub
        let newSelf = Curve25519.KeyAgreement.PrivateKey()
        dhSelfPriv = newSelf.rawRepresentation
        let sendOut = try newSelf.sharedSecretFromKeyAgreement(with: remote)
        let (root2, sendChain) = Self.kdfRoot(rootKey, dhOut: sendOut)
        rootKey = root2
        sendChainKey = sendChain
    }
}
