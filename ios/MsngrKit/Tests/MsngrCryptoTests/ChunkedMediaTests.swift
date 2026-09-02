import XCTest
import CryptoKit
@testable import MsngrCrypto

/// Media format 2: every block opens on its own, and nothing opens once the
/// blob, the manifest or a block's place in it has been touched.
final class ChunkedMediaTests: XCTestCase {
    private func sample(_ bytes: Int) -> Data {
        var d = Data(count: bytes)
        for i in 0..<bytes { d[i] = UInt8((i * 31 + 7) & 0xff) }
        return d
    }

    func testLayoutIsComputableFromThePlaintextSize() {
        let size = MediaCrypto.blockSize * 2 + 100
        XCTAssertEqual(MediaCrypto.blockCount(plaintextSize: size), 3)
        XCTAssertEqual(MediaCrypto.blockRange(index: 0, plaintextSize: size),
                       0..<(MediaCrypto.blockSize + MediaCrypto.tagSize))
        XCTAssertEqual(MediaCrypto.blockRange(index: 2, plaintextSize: size).count,
                       100 + MediaCrypto.tagSize)
        XCTAssertEqual(MediaCrypto.blobSize(plaintextSize: size),
                       size + 3 * MediaCrypto.tagSize + 3 * MediaCrypto.hashSize)
        let enc = try! MediaCrypto.encryptChunked(sample(size))
        XCTAssertEqual(enc.blob.count, MediaCrypto.blobSize(plaintextSize: size))
    }

    func testWholeFileRoundTrip() throws {
        for size in [1, 1000, MediaCrypto.blockSize, MediaCrypto.blockSize + 1,
                     MediaCrypto.blockSize * 3 + 12345] {
            let plain = sample(size)
            let enc = try MediaCrypto.encryptChunked(plain)
            XCTAssertEqual(try MediaCrypto.decryptChunked(enc.blob, key: enc.key,
                                                          root: enc.root, plaintextSize: size),
                           plain)
        }
    }

    func testOneBlockOpensWithoutTheRest() throws {
        let size = MediaCrypto.blockSize * 4 + 77
        let plain = sample(size)
        let enc = try MediaCrypto.encryptChunked(plain)
        let mr = MediaCrypto.manifestRange(plaintextSize: size)
        let hashes = try MediaCrypto.parseManifest(enc.blob[mr], plaintextSize: size,
                                                   expectedRoot: enc.root)
        // the third block, taken out of the middle of the blob by itself
        let r = MediaCrypto.blockRange(index: 2, plaintextSize: size)
        let block = try MediaCrypto.openBlock(Data(enc.blob[r]), index: 2, key: enc.key,
                                              expectedHash: hashes[2])
        XCTAssertEqual(block, plain[(2 * MediaCrypto.blockSize)..<(3 * MediaCrypto.blockSize)])
        // and the last, shorter one
        let last = MediaCrypto.blockRange(index: 4, plaintextSize: size)
        XCTAssertEqual(try MediaCrypto.openBlock(Data(enc.blob[last]), index: 4, key: enc.key,
                                                 expectedHash: hashes[4]).count, 77)
    }

    func testABlockFromAnotherPositionDoesNotOpen() throws {
        let size = MediaCrypto.blockSize * 2
        let enc = try MediaCrypto.encryptChunked(sample(size))
        let mr = MediaCrypto.manifestRange(plaintextSize: size)
        let hashes = try MediaCrypto.parseManifest(enc.blob[mr], plaintextSize: size,
                                                   expectedRoot: enc.root)
        let r = MediaCrypto.blockRange(index: 0, plaintextSize: size)
        XCTAssertThrowsError(try MediaCrypto.openBlock(Data(enc.blob[r]), index: 1, key: enc.key,
                                                       expectedHash: hashes[0]))
    }

    func testATouchedBlockFailsItsHash() throws {
        let size = MediaCrypto.blockSize + 5
        let enc = try MediaCrypto.encryptChunked(sample(size))
        let mr = MediaCrypto.manifestRange(plaintextSize: size)
        let hashes = try MediaCrypto.parseManifest(enc.blob[mr], plaintextSize: size,
                                                   expectedRoot: enc.root)
        let r = MediaCrypto.blockRange(index: 0, plaintextSize: size)
        var block = Data(enc.blob[r])
        block[10] ^= 1
        XCTAssertThrowsError(try MediaCrypto.openBlock(block, index: 0, key: enc.key,
                                                       expectedHash: hashes[0]))
    }

    func testTheManifestIsRejectedWhenItDoesNotMatchTheRoot() throws {
        let size = MediaCrypto.blockSize * 2
        let enc = try MediaCrypto.encryptChunked(sample(size))
        let mr = MediaCrypto.manifestRange(plaintextSize: size)
        var manifest = Data(enc.blob[mr])
        // two blocks swapped in the manifest, so the root no longer holds
        let first = Data(manifest[0..<MediaCrypto.hashSize])
        manifest.replaceSubrange(0..<MediaCrypto.hashSize,
                                 with: manifest[MediaCrypto.hashSize..<(2 * MediaCrypto.hashSize)])
        manifest.replaceSubrange(MediaCrypto.hashSize..<(2 * MediaCrypto.hashSize), with: first)
        XCTAssertThrowsError(try MediaCrypto.parseManifest(manifest, plaintextSize: size,
                                                           expectedRoot: enc.root))
        manifest[3] ^= 1
        XCTAssertThrowsError(try MediaCrypto.parseManifest(manifest, plaintextSize: size,
                                                           expectedRoot: enc.root))
    }

    func testTheRootCommitsToThePlaintextSize() throws {
        let size = MediaCrypto.blockSize * 2
        let enc = try MediaCrypto.encryptChunked(sample(size))
        XCTAssertThrowsError(try MediaCrypto.decryptChunked(enc.blob, key: enc.key,
                                                            root: enc.root,
                                                            plaintextSize: size - 1))
    }

    func testAWrongKeyDoesNotOpenABlock() throws {
        let size = 4096
        let enc = try MediaCrypto.encryptChunked(sample(size))
        let other = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        XCTAssertThrowsError(try MediaCrypto.decryptChunked(enc.blob, key: other,
                                                            root: enc.root, plaintextSize: size))
    }
}
