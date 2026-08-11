import CryptoKit
import Foundation

/// Идентичность устройства: X25519 для DH + Ed25519 для подписей.
/// (Signal использует XEd25519 поверх одного ключа; CryptoKit не умеет
/// конвертацию, поэтому пара раздельных ключей, X25519-ключ подписан Ed25519.)
public struct IdentityKeyPair: Sendable {
    public let dh: Curve25519.KeyAgreement.PrivateKey
    public let signing: Curve25519.Signing.PrivateKey

    public init() {
        self.dh = .init()
        self.signing = .init()
    }

    public init(dhRaw: Data, signingRaw: Data) throws {
        self.dh = try .init(rawRepresentation: dhRaw)
        self.signing = try .init(rawRepresentation: signingRaw)
    }

    public var publicKeys: IdentityPublicKeys {
        IdentityPublicKeys(dh: dh.publicKey.rawRepresentation,
                           signing: signing.publicKey.rawRepresentation)
    }
}

public struct IdentityPublicKeys: Sendable, Equatable {
    public let dh: Data       // X25519 pub
    public let signing: Data  // Ed25519 pub

    public init(dh: Data, signing: Data) {
        self.dh = dh
        self.signing = signing
    }
}

public struct SignedPreKey: Sendable {
    public let id: UInt32
    public let key: Curve25519.KeyAgreement.PrivateKey
    public let signature: Data  // Ed25519(identity.signing, key.pub)

    public init(id: UInt32, identity: IdentityKeyPair) throws {
        self.id = id
        self.key = .init()
        self.signature = try identity.signing.signature(for: key.publicKey.rawRepresentation)
    }
}

public struct OneTimePreKey: Sendable {
    public let id: UInt32
    public let key: Curve25519.KeyAgreement.PrivateKey

    public init(id: UInt32) {
        self.id = id
        self.key = .init()
    }
}

/// Prekey-бандл собеседника, полученный с сервера.
public struct PreKeyBundle: Sendable {
    public let identity: IdentityPublicKeys
    public let signedPreKeyId: UInt32
    public let signedPreKey: Data
    public let signedPreKeySignature: Data
    public let oneTimePreKeyId: UInt32?
    public let oneTimePreKey: Data?

    public init(identity: IdentityPublicKeys, signedPreKeyId: UInt32, signedPreKey: Data,
                signedPreKeySignature: Data, oneTimePreKeyId: UInt32?, oneTimePreKey: Data?) {
        self.identity = identity
        self.signedPreKeyId = signedPreKeyId
        self.signedPreKey = signedPreKey
        self.signedPreKeySignature = signedPreKeySignature
        self.oneTimePreKeyId = oneTimePreKeyId
        self.oneTimePreKey = oneTimePreKey
    }

    public func verifySignature() -> Bool {
        guard let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: identity.signing)
        else { return false }
        return pub.isValidSignature(signedPreKeySignature, for: signedPreKey)
    }
}

public enum CryptoError: Error, Equatable {
    case invalidKey
    case invalidSignature
    case decryptionFailed
    case invalidMessage
    case noSession
    case tooManySkipped
    case duplicateMessage
}
