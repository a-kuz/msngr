import CryptoKit
import Foundation

/// X3DH (Signal): установление общего секрета через prekey-бандл.
public enum X3DH {
    static let info = Data("MsngrX3DH".utf8)
    static let f = Data(repeating: 0xFF, count: 32) // префикс по спеке X3DH

    public struct InitiatorResult: Sendable {
        public let sharedSecret: SymmetricKey
        public let ephemeralPublic: Data
        public let associatedData: Data // IK_a || IK_b
    }

    /// Инициатор: Алиса начинает сессию с бандлом Боба.
    public static func initiate(
        our: IdentityKeyPair,
        their: PreKeyBundle
    ) throws -> InitiatorResult {
        guard their.verifySignature() else { throw CryptoError.invalidSignature }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let ikB = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: their.identity.dh)
        let spkB = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: their.signedPreKey)

        let dh1 = try our.dh.sharedSecretFromKeyAgreement(with: spkB)
        let dh2 = try ephemeral.sharedSecretFromKeyAgreement(with: ikB)
        let dh3 = try ephemeral.sharedSecretFromKeyAgreement(with: spkB)

        var material = f
        dh1.withUnsafeBytes { material.append(contentsOf: $0) }
        dh2.withUnsafeBytes { material.append(contentsOf: $0) }
        dh3.withUnsafeBytes { material.append(contentsOf: $0) }

        if let otpData = their.oneTimePreKey {
            let otp = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: otpData)
            let dh4 = try ephemeral.sharedSecretFromKeyAgreement(with: otp)
            dh4.withUnsafeBytes { material.append(contentsOf: $0) }
        }

        let sk = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: material),
            salt: Data(repeating: 0, count: 32),
            info: info,
            outputByteCount: 32
        )
        let ad = our.dh.publicKey.rawRepresentation + their.identity.dh
        return InitiatorResult(sharedSecret: sk,
                               ephemeralPublic: ephemeral.publicKey.rawRepresentation,
                               associatedData: ad)
    }

    public struct ResponderResult: Sendable {
        public let sharedSecret: SymmetricKey
        public let associatedData: Data
    }

    /// Ответчик: Боб восстанавливает секрет из PreKey-сообщения Алисы.
    public static func respond(
        our: IdentityKeyPair,
        ourSignedPreKey: Curve25519.KeyAgreement.PrivateKey,
        ourOneTimePreKey: Curve25519.KeyAgreement.PrivateKey?,
        theirIdentityDH: Data,
        theirEphemeral: Data
    ) throws -> ResponderResult {
        let ikA = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirIdentityDH)
        let ekA = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirEphemeral)

        let dh1 = try ourSignedPreKey.sharedSecretFromKeyAgreement(with: ikA)
        let dh2 = try our.dh.sharedSecretFromKeyAgreement(with: ekA)
        let dh3 = try ourSignedPreKey.sharedSecretFromKeyAgreement(with: ekA)

        var material = f
        dh1.withUnsafeBytes { material.append(contentsOf: $0) }
        dh2.withUnsafeBytes { material.append(contentsOf: $0) }
        dh3.withUnsafeBytes { material.append(contentsOf: $0) }

        if let otp = ourOneTimePreKey {
            let dh4 = try otp.sharedSecretFromKeyAgreement(with: ekA)
            dh4.withUnsafeBytes { material.append(contentsOf: $0) }
        }

        let sk = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: material),
            salt: Data(repeating: 0, count: 32),
            info: info,
            outputByteCount: 32
        )
        let ad = theirIdentityDH + our.dh.publicKey.rawRepresentation
        return ResponderResult(sharedSecret: sk, associatedData: ad)
    }
}
