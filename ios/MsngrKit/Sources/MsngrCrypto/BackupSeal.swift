import CryptoKit
import Foundation

/// Sealing an account backup under a recovery code.
///
/// The code is generated on the device that turns backup on, shown once, and
/// never stored anywhere the device does not control: it is the only way back
/// into a backup, there is no password reset. It is high-entropy random bytes
/// rather than a memorized passphrase, so it goes into HKDF directly, the same
/// way every other key derivation in this module starts from a high-entropy
/// secret rather than from something a person typed.
public enum BackupSeal {
    static let info = Data("MsngrBackup/1".utf8)
    /// 120 bits: divides evenly into Crockford base32's 5-bit symbols (24 of
    /// them, no padding) and is comfortably beyond what a network attacker
    /// could search before a stolen backup blob goes stale.
    static let recoveryCodeBytes = 15

    public enum Failure: Error, Equatable {
        case badFormat
        case unsupportedVersion
        case decryptionFailed
    }

    public static func generateRecoveryCode() -> String {
        var bytes = [UInt8](repeating: 0, count: recoveryCodeBytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Crockford32.encode(Data(bytes))
    }

    /// Grouped for reading and typing back: four characters, a dash, four more.
    public static func formatRecoveryCode(_ code: String) -> String {
        var out = ""
        for (i, ch) in code.enumerated() {
            if i > 0 && i % 4 == 0 { out.append("-") }
            out.append(ch)
        }
        return out
    }

    public static func normalizeRecoveryCode(_ typed: String) -> String {
        String(typed.uppercased().unicodeScalars.filter {
            ("0"..."9").contains(String($0)) || ("A"..."Z").contains(String($0))
        }.map(Character.init))
    }

    private static func key(recoveryCode: String) throws -> SymmetricKey {
        let normalized = normalizeRecoveryCode(recoveryCode)
        guard let raw = Crockford32.decode(normalized), raw.count == recoveryCodeBytes else {
            throw Failure.badFormat
        }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: raw),
                                      info: info, outputByteCount: 32)
    }

    /// What actually leaves the device: a version tag and one ChaChaPoly box.
    /// This is the whole content of a `.msngrbackup` file.
    public struct SealedBackup: Codable, Sendable {
        public let v: Int
        public let ct: String

        public init(v: Int, ct: String) {
            self.v = v
            self.ct = ct
        }
    }

    public static func seal<T: Encodable>(_ payload: T, recoveryCode: String) throws -> SealedBackup {
        let box = try ChaChaPoly.seal(JSONEncoder().encode(payload), using: try key(recoveryCode: recoveryCode))
        return SealedBackup(v: 1, ct: box.combined.base64urlEncodedString())
    }

    public static func open<T: Decodable>(_ sealed: SealedBackup, recoveryCode: String,
                                          as type: T.Type) throws -> T {
        guard sealed.v == 1 else { throw Failure.unsupportedVersion }
        guard let ct = Data(base64urlEncoded: sealed.ct) else { throw Failure.badFormat }
        guard let box = try? ChaChaPoly.SealedBox(combined: ct),
              let plain = try? ChaChaPoly.open(box, using: try key(recoveryCode: recoveryCode))
        else { throw Failure.decryptionFailed }
        return try JSONDecoder().decode(T.self, from: plain)
    }
}

/// Crockford base32: 32 symbols, no I/L/O/U, so a misread character is never
/// mistaken for a different valid one. Same alphabet the server's ulid and
/// provisioning code already use.
enum Crockford32 {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func encode(_ data: Data) -> String {
        var bits = 0
        var value = 0
        var out = ""
        for byte in data {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[(value >> bits) & 0x1F])
            }
        }
        if bits > 0 {
            out.append(alphabet[(value << (5 - bits)) & 0x1F])
        }
        return out
    }

    static func decode(_ string: String) -> Data? {
        var value = 0
        var bits = 0
        var out = [UInt8]()
        for ch in string {
            guard let idx = alphabet.firstIndex(of: ch) else { return nil }
            value = (value << 5) | idx
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((value >> bits) & 0xFF))
            }
        }
        return Data(out)
    }
}
