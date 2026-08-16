import CryptoKit
import Foundation

/// Handing an account to a device its owner has just authorised.
///
/// The device being linked generates an ephemeral X25519 pair and publishes the
/// public half with its provisioning session; the device that approves seals the
/// account bundle to it with a keypair of its own. The server carries the result
/// and cannot open it: it never sees either private half.
public enum Provisioning {
    static let info = Data("MsngrProvision/1".utf8)

    /// The ephemeral pair the device being linked keeps until the bundle
    /// arrives. It lives in memory for the life of one provisioning session.
    public struct EphemeralKeyPair: Sendable {
        public let priv: Curve25519.KeyAgreement.PrivateKey
        public var publicKey: Data { priv.publicKey.rawRepresentation }

        public init() { self.priv = .init() }
    }

    /// What the approving device puts on the server.
    public struct SealedBundle: Codable, Sendable {
        public let v: Int
        /// Public half of the pair the approving device made for this session.
        public let epk: String
        /// ChaChaPoly combined box over the bundle JSON.
        public let ct: String
    }

    /// The account, as one device hands it to another. The identity keys are the
    /// account's; everything else a linked device makes for itself.
    public struct Bundle: Codable, Sendable {
        public let v: Int
        public let userId: String
        public let username: String
        public let displayName: String
        /// Raw X25519 private key, base64url.
        public let identityDH: String
        /// Raw Ed25519 private key, base64url.
        public let identitySigning: String

        public init(userId: String, username: String, displayName: String,
                    identityDH: String, identitySigning: String) {
            self.v = 1
            self.userId = userId
            self.username = username
            self.displayName = displayName
            self.identityDH = identityDH
            self.identitySigning = identitySigning
        }
    }

    public enum Failure: Error, Equatable {
        case badFormat
        case unsupportedVersion
        case decryptionFailed
    }

    /// Binds the box to the session and to both halves of the exchange: a bundle
    /// lifted from one session cannot be replayed into another, and neither
    /// public key can be swapped without the key changing with it.
    private static func key(shared: SharedSecret, provisionId: String,
                            senderPub: Data, recipientPub: Data) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(provisionId.utf8),
            sharedInfo: info + senderPub + recipientPub,
            outputByteCount: 32)
    }

    public static func seal(_ bundle: Bundle, to recipientPub: Data,
                            provisionId: String) throws -> SealedBundle {
        let sender = Curve25519.KeyAgreement.PrivateKey()
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPub)
        let shared = try sender.sharedSecretFromKeyAgreement(with: recipient)
        let senderPub = sender.publicKey.rawRepresentation
        let box = try ChaChaPoly.seal(
            JSONEncoder().encode(bundle),
            using: key(shared: shared, provisionId: provisionId,
                       senderPub: senderPub, recipientPub: recipientPub))
        return SealedBundle(v: 1, epk: senderPub.base64urlEncodedString(),
                            ct: box.combined.base64urlEncodedString())
    }

    public static func open(_ sealed: SealedBundle, with ephemeral: EphemeralKeyPair,
                            provisionId: String) throws -> Bundle {
        guard sealed.v == 1 else { throw Failure.unsupportedVersion }
        guard let senderPub = Data(base64urlEncoded: sealed.epk),
              let ct = Data(base64urlEncoded: sealed.ct) else { throw Failure.badFormat }
        guard let sender = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: senderPub),
              let shared = try? ephemeral.priv.sharedSecretFromKeyAgreement(with: sender),
              let box = try? ChaChaPoly.SealedBox(combined: ct),
              let plain = try? ChaChaPoly.open(
                box, using: key(shared: shared, provisionId: provisionId,
                                senderPub: senderPub, recipientPub: ephemeral.publicKey))
        else { throw Failure.decryptionFailed }
        let bundle = try JSONDecoder().decode(Bundle.self, from: plain)
        guard bundle.v == 1 else { throw Failure.unsupportedVersion }
        return bundle
    }
}
