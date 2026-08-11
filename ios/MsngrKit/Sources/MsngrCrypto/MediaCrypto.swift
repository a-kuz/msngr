import CryptoKit
import Foundation

/// Шифрование медиа: файл → ChaChaPoly случайным ключом; ключ и SHA-256
/// ciphertext'а едут внутри E2E-сообщения, сервер видит только блоб.
public enum MediaCrypto {
    public struct Encrypted: Sendable {
        public let ciphertext: Data
        public let key: Data      // 32 байта
        public let sha256: Data   // хэш ciphertext — верификация после скачивания
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

/// Safety numbers: 60 цифр из отпечатков identity-ключей обеих сторон
/// (5200 итераций SHA-512, как в Signal) — сверка личности вне канала.
public enum SafetyNumbers {
    private static func fingerprint(identity: Data, userId: String) -> String {
        var digest = Data([0, 0]) + identity + Data(userId.utf8)
        for _ in 0..<5200 {
            digest = Data(SHA512.hash(data: digest + identity))
        }
        // 30 цифр из первых 20 байт
        var out = ""
        for i in 0..<6 {
            let chunk = digest.subdata(in: (i * 5)..<(i * 5 + 5))
            var v: UInt64 = 0
            for b in chunk { v = v << 8 | UInt64(b) }
            out += String(format: "%05d", v % 100_000)
        }
        return out
    }

    public static func generate(ourIdentitySigning: Data, ourUserId: String,
                                theirIdentitySigning: Data, theirUserId: String) -> String {
        let a = fingerprint(identity: ourIdentitySigning, userId: ourUserId)
        let b = fingerprint(identity: theirIdentitySigning, userId: theirUserId)
        return [a, b].sorted().joined()
    }
}
