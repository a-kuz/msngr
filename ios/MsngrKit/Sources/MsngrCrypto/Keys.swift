import CryptoKit
import Foundation

/// Binds the two halves of an identity to each other.
///
/// Signal derives both from a single key via XEd25519; CryptoKit cannot convert
/// between the two curves, so the identity holds two separate keys and the
/// X25519 one is signed by the Ed25519 one. Without that signature the key a
/// peer is trusted by (Ed25519, which is public and served by the server) and
/// the key their messages are encrypted under (X25519) are unrelated values,
/// and anyone routing envelopes can pair a real identity with a key of its own.
public enum IdentityBinding {
    static let context = Data("MsngrIdentityDH/1".utf8)

    static func message(dh: Data) -> Data { context + dh }

    public static func sign(dh: Data, with signing: Curve25519.Signing.PrivateKey) throws -> Data {
        try signing.signature(for: message(dh: dh))
    }

    public static func verify(dh: Data, signature: Data, signingPub: Data) -> Bool {
        guard let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: signingPub)
        else { return false }
        return pub.isValidSignature(signature, for: message(dh: dh))
    }
}

/// Device identity: X25519 for DH, Ed25519 for signatures, the first signed by
/// the second (`IdentityBinding`).
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

    /// The signature that ties this identity's X25519 key to its Ed25519 one.
    /// It travels with the key everywhere the key does: registration, the claim
    /// of a linked device, and every prekey envelope.
    public var dhSignature: Data {
        get throws { try IdentityBinding.sign(dh: dh.publicKey.rawRepresentation, with: signing) }
    }

    public var publicKeys: IdentityPublicKeys {
        get throws {
            IdentityPublicKeys(dh: dh.publicKey.rawRepresentation,
                               signing: signing.publicKey.rawRepresentation,
                               dhSignature: try dhSignature)
        }
    }
}

public struct IdentityPublicKeys: Sendable, Equatable {
    public let dh: Data           // X25519 pub
    public let signing: Data      // Ed25519 pub
    public let dhSignature: Data  // Ed25519(signing, IdentityBinding.message(dh))

    public init(dh: Data, signing: Data, dhSignature: Data) {
        self.dh = dh
        self.signing = signing
        self.dhSignature = dhSignature
    }

    /// Whether the X25519 half really belongs to the Ed25519 half.
    public var isBound: Bool {
        IdentityBinding.verify(dh: dh, signature: dhSignature, signingPub: signing)
    }

    /// An identity is its two keys. CryptoKit signs Ed25519 with randomness, so
    /// the binding is different bytes every time it is made over the same key
    /// and says nothing about which identity this is.
    public static func == (a: IdentityPublicKeys, b: IdentityPublicKeys) -> Bool {
        a.dh == b.dh && a.signing == b.signing
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

/// A peer's prekey bundle as fetched from the server.
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

    /// Both signatures the bundle stands on: the identity's own binding, and the
    /// signed prekey under the identity.
    public func verifySignature() -> Bool {
        guard identity.isBound,
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: identity.signing)
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
