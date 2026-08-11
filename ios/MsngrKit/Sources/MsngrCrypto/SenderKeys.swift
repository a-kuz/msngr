import CryptoKit
import Foundation

/// Sender Keys (Signal group messaging): у каждого участника своя цепочка
/// на группу, распространяется pairwise-каналами. Подпись Ed25519 на каждом
/// сообщении — аутентификация внутри группы.
public struct SenderKeyDistribution: Codable, Sendable {
    public let keyId: String       // uuid цепочки
    public let iteration: UInt32   // с какой итерации знает получатель
    public let chainKey: Data
    public let signingPub: Data    // Ed25519 pub отправителя для этой цепочки

    public init(keyId: String, iteration: UInt32, chainKey: Data, signingPub: Data) {
        self.keyId = keyId
        self.iteration = iteration
        self.chainKey = chainKey
        self.signingPub = signingPub
    }
}

public struct SenderKeyMessage: Codable, Sendable {
    public let keyId: String
    public let iteration: UInt32
    public let ciphertext: Data
    public let signature: Data

    public init(keyId: String, iteration: UInt32, ciphertext: Data, signature: Data) {
        self.keyId = keyId
        self.iteration = iteration
        self.ciphertext = ciphertext
        self.signature = signature
    }
}

/// Состояние своей отправной цепочки в группе.
public struct SenderKeyState: Codable, Sendable {
    public let keyId: String
    var chainKey: Data
    var iteration: UInt32
    let signingPriv: Data

    public init() {
        self.keyId = UUID().uuidString
        var bytes = Data(count: 32)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        self.chainKey = bytes
        self.iteration = 0
        self.signingPriv = Curve25519.Signing.PrivateKey().rawRepresentation
    }

    public var distribution: SenderKeyDistribution {
        get throws {
            let priv = try Curve25519.Signing.PrivateKey(rawRepresentation: signingPriv)
            return SenderKeyDistribution(keyId: keyId, iteration: iteration,
                                         chainKey: chainKey,
                                         signingPub: priv.publicKey.rawRepresentation)
        }
    }

    static func kdf(_ chainKey: Data) -> (next: Data, message: Data) {
        let next = HMAC<SHA256>.authenticationCode(for: Data([0x02]), using: SymmetricKey(data: chainKey))
        let msg = HMAC<SHA256>.authenticationCode(for: Data([0x01]), using: SymmetricKey(data: chainKey))
        return (Data(next), Data(msg))
    }

    public mutating func encrypt(_ plaintext: Data) throws -> SenderKeyMessage {
        let (next, msgKey) = Self.kdf(chainKey)
        let sealed = try ChaChaPoly.seal(plaintext, using: SymmetricKey(data: msgKey))
        let priv = try Curve25519.Signing.PrivateKey(rawRepresentation: signingPriv)
        let sig = try priv.signature(for: sealed.combined)
        let msg = SenderKeyMessage(keyId: keyId, iteration: iteration,
                                   ciphertext: sealed.combined, signature: sig)
        chainKey = next
        iteration += 1
        return msg
    }
}

/// Состояние чужой цепочки (получатель).
public struct SenderKeyReceiver: Codable, Sendable {
    public let keyId: String
    var chainKey: Data
    var iteration: UInt32
    let signingPub: Data
    var skipped: [UInt32: Data] = [:]

    static let maxSkip: UInt32 = 2000

    public init(distribution: SenderKeyDistribution) {
        self.keyId = distribution.keyId
        self.chainKey = distribution.chainKey
        self.iteration = distribution.iteration
        self.signingPub = distribution.signingPub
    }

    public mutating func decrypt(_ message: SenderKeyMessage) throws -> Data {
        let pub = try Curve25519.Signing.PublicKey(rawRepresentation: signingPub)
        guard pub.isValidSignature(message.signature, for: message.ciphertext) else {
            throw CryptoError.invalidSignature
        }
        let msgKey: Data
        if let sk = skipped[message.iteration] {
            skipped.removeValue(forKey: message.iteration)
            msgKey = sk
        } else {
            guard message.iteration >= iteration else { throw CryptoError.duplicateMessage }
            guard message.iteration - iteration <= Self.maxSkip else { throw CryptoError.tooManySkipped }
            var ck = chainKey
            var it = iteration
            while it < message.iteration {
                let (next, mk) = SenderKeyState.kdf(ck)
                skipped[it] = mk
                ck = next
                it += 1
            }
            let (next, mk) = SenderKeyState.kdf(ck)
            chainKey = next
            iteration = it + 1
            msgKey = mk
        }
        do {
            let box = try ChaChaPoly.SealedBox(combined: message.ciphertext)
            return try ChaChaPoly.open(box, using: SymmetricKey(data: msgKey))
        } catch {
            throw CryptoError.decryptionFailed
        }
    }
}
