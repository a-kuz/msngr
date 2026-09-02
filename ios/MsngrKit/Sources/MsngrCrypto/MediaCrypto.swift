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

/// Media format 2: the file is cut into fixed-size blocks, each sealed with
/// ChaChaPoly on its own and hashed on its own, so a player can take any block
/// out of the middle, check it and decrypt it without the rest of the file.
///
/// The blob on the server is the sealed blocks back to back, followed by the
/// manifest — the SHA-256 of every sealed block in order. Nothing else is
/// stored: block `i` starts at `i * (blockSize + tagSize)` and the manifest
/// starts right after the last block, both computable from the plaintext size
/// that travels in `MediaInfo.size`, so a reader needs no header request to
/// find anything.
///
/// The nonce of block `i` is the index itself, big-endian in the low eight
/// bytes. The key is fresh per file, so no nonce ever repeats, and a block
/// moved to another position stops opening. The manifest's root hash travels
/// in `MediaInfo.hash` and commits to the block hashes, the plaintext size and
/// the block size together: a truncated, extended or reordered file fails
/// before a single block is decrypted.
public extension MediaCrypto {
    /// The plaintext size of one block.
    static let blockSize = 256 * 1024
    static let tagSize = 16
    static let hashSize = 32

    struct EncryptedChunked: Sendable {
        public let blob: Data     // sealed blocks + manifest
        public let key: Data      // 32 bytes
        public let root: Data     // manifest root, verified before any block
    }

    static func blockCount(plaintextSize: Int) -> Int {
        plaintextSize <= 0 ? 0 : (plaintextSize + blockSize - 1) / blockSize
    }

    /// Where block `index` starts in the blob and how many bytes it takes.
    static func blockRange(index: Int, plaintextSize: Int) -> Range<Int> {
        let start = index * (blockSize + tagSize)
        let plainStart = index * blockSize
        let plain = min(blockSize, max(0, plaintextSize - plainStart))
        return start..<(start + plain + tagSize)
    }

    static func manifestRange(plaintextSize: Int) -> Range<Int> {
        let count = blockCount(plaintextSize: plaintextSize)
        let start = plaintextSize + count * tagSize
        return start..<(start + count * hashSize)
    }

    static func blobSize(plaintextSize: Int) -> Int {
        manifestRange(plaintextSize: plaintextSize).upperBound
    }

    static func manifestRoot(hashes: [Data], plaintextSize: Int) -> Data {
        var input = Data("msngrm2".utf8)
        var size = UInt64(plaintextSize).bigEndian
        withUnsafeBytes(of: &size) { input.append(contentsOf: $0) }
        var block = UInt32(blockSize).bigEndian
        withUnsafeBytes(of: &block) { input.append(contentsOf: $0) }
        for h in hashes { input.append(h) }
        return Data(SHA256.hash(data: input))
    }

    static func nonce(forBlock index: Int) throws -> ChaChaPoly.Nonce {
        var raw = Data(count: 4)
        var be = UInt64(index).bigEndian
        withUnsafeBytes(of: &be) { raw.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: raw)
    }

    static func encryptChunked(_ plaintext: Data) throws -> EncryptedChunked {
        let key = SymmetricKey(size: .bits256)
        let count = blockCount(plaintextSize: plaintext.count)
        var blob = Data(capacity: blobSize(plaintextSize: plaintext.count))
        var hashes: [Data] = []
        hashes.reserveCapacity(count)
        for i in 0..<count {
            let start = plaintext.startIndex + i * blockSize
            let end = min(start + blockSize, plaintext.endIndex)
            let sealed = try ChaChaPoly.seal(plaintext[start..<end], using: key,
                                             nonce: nonce(forBlock: i))
            let bytes = sealed.ciphertext + sealed.tag
            blob.append(bytes)
            hashes.append(Data(SHA256.hash(data: bytes)))
        }
        for h in hashes { blob.append(h) }
        return EncryptedChunked(blob: blob,
                                key: key.withUnsafeBytes { Data($0) },
                                root: manifestRoot(hashes: hashes, plaintextSize: plaintext.count))
    }

    /// Splits the manifest bytes into block hashes after checking them against
    /// the root that came in the message.
    static func parseManifest(_ data: Data, plaintextSize: Int, expectedRoot: Data) throws -> [Data] {
        let count = blockCount(plaintextSize: plaintextSize)
        guard data.count == count * hashSize else { throw CryptoError.invalidMessage }
        var hashes: [Data] = []
        hashes.reserveCapacity(count)
        for i in 0..<count {
            let start = data.startIndex + i * hashSize
            hashes.append(Data(data[start..<(start + hashSize)]))
        }
        guard manifestRoot(hashes: hashes, plaintextSize: plaintextSize) == expectedRoot else {
            throw CryptoError.invalidMessage
        }
        return hashes
    }

    /// One block: its hash is checked against the manifest first, then the seal
    /// is opened under the nonce its index gives it.
    static func openBlock(_ sealed: Data, index: Int, key: Data, expectedHash: Data) throws -> Data {
        guard Data(SHA256.hash(data: sealed)) == expectedHash,
              sealed.count > tagSize else { throw CryptoError.invalidMessage }
        let split = sealed.endIndex - tagSize
        let box = try ChaChaPoly.SealedBox(nonce: nonce(forBlock: index),
                                          ciphertext: sealed[sealed.startIndex..<split],
                                          tag: sealed[split..<sealed.endIndex])
        return try ChaChaPoly.open(box, using: SymmetricKey(data: key))
    }

    /// The whole file at once, for the paths that have no reason to stream.
    static func decryptChunked(_ blob: Data, key: Data, root: Data, plaintextSize: Int) throws -> Data {
        guard blob.count == blobSize(plaintextSize: plaintextSize) else {
            throw CryptoError.invalidMessage
        }
        let mr = manifestRange(plaintextSize: plaintextSize)
        let hashes = try parseManifest(blob[(blob.startIndex + mr.lowerBound)..<(blob.startIndex + mr.upperBound)],
                                       plaintextSize: plaintextSize, expectedRoot: root)
        var out = Data(capacity: plaintextSize)
        for i in hashes.indices {
            let r = blockRange(index: i, plaintextSize: plaintextSize)
            out.append(try openBlock(Data(blob[(blob.startIndex + r.lowerBound)..<(blob.startIndex + r.upperBound)]),
                                     index: i, key: key, expectedHash: hashes[i]))
        }
        return out
    }
}
