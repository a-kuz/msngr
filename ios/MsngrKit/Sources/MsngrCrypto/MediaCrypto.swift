import CryptoKit
import Foundation

/// Media encryption: the file is sealed with ChaChaPoly under a fresh random
/// key. The key and the SHA-256 of the ciphertext travel inside the E2E
/// message, so the server only ever holds an opaque blob.
public enum MediaCrypto {
    public struct Encrypted: Sendable {
        public let ciphertext: Data
        public let key: Data      // 32 bytes
        public let sha256: Data   // ciphertext hash, verified after download
    }

    public static func encrypt(_ plaintext: Data) throws -> Encrypted {
        let key = SymmetricKey(size: .bits256)
        let sealed = try ChaChaPoly.seal(plaintext, using: key)
        let combined = sealed.combined
        return Encrypted(ciphertext: combined,
                         key: key.withUnsafeBytes { Data($0) },
                         sha256: Data(SHA256.hash(data: combined)))
    }

    public static func decrypt(_ ciphertext: Data, key: Data, expectedSHA256: Data) throws -> Data {
        guard Data(SHA256.hash(data: ciphertext)) == expectedSHA256 else {
            throw CryptoError.invalidMessage
        }
        let box = try ChaChaPoly.SealedBox(combined: ciphertext)
        return try ChaChaPoly.open(box, using: SymmetricKey(data: key))
    }
}

/// Safety numbers: 60 digits built from both sides' identity key fingerprints
/// (5200 SHA-512 iterations, as in Signal), for verifying identity out of band.
///
/// Both halves of an identity go into the fingerprint. The X25519 key is the one
/// messages are encrypted under, so a code that covered only the Ed25519 key
/// would read the same whether or not the encryption key was the peer's.
public enum SafetyNumbers {
    private static func fingerprint(identity: Data, userId: String) -> String {
        var digest = Data([0, 0]) + identity + Data(userId.utf8)
        for _ in 0..<5200 {
            digest = Data(SHA512.hash(data: digest + identity))
        }
        // 30 digits per side: five from each 5-byte chunk of the digest
        var out = ""
        for i in 0..<6 {
            let chunk = digest.subdata(in: (i * 5)..<(i * 5 + 5))
            var v: UInt64 = 0
            for b in chunk { v = v << 8 | UInt64(b) }
            out += String(format: "%05d", v % 100_000)
        }
        return out
    }

    public static func generate(ourIdentitySigning: Data, ourIdentityDH: Data, ourUserId: String,
                                theirIdentitySigning: Data, theirIdentityDH: Data,
                                theirUserId: String) -> String {
        let a = fingerprint(identity: ourIdentitySigning + ourIdentityDH, userId: ourUserId)
        let b = fingerprint(identity: theirIdentitySigning + theirIdentityDH, userId: theirUserId)
        return [a, b].sorted().joined()
    }
}
