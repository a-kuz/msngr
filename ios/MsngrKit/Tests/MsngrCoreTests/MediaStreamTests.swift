import XCTest
import MsngrCrypto
@testable import MsngrCore

/// Streaming a block-format blob: a range is answered from the blocks it falls
/// in, the rest of the file is never asked for, and once every block is in the
/// file lands in the cache as ordinary plaintext.
final class MediaStreamTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Counts what a stream asked the server for, so a test can say a range
    /// was served without the whole blob crossing the wire.
    private final class Server: @unchecked Sendable {
        let blob: Data
        var requested = 0
        var corruptAt: Int?
        private let lock = NSLock()
        init(_ blob: Data) { self.blob = blob }
        var fetch: MediaStream.RangeFetch {
            { [self] offset, length in
                lock.lock()
                requested += length
                var slice = blob.subdata(in: offset..<(offset + length))
                if let at = corruptAt, at >= offset, at < offset + length { slice[at - offset] ^= 1 }
                lock.unlock()
                return slice
            }
        }
    }

    private func plaintext(_ bytes: Int) -> Data {
        var d = Data(count: bytes)
        for i in 0..<bytes { d[i] = UInt8((i * 17 + 3) & 0xff) }
        return d
    }

    private func makeStream(_ plain: Data, server: Server, enc: MediaCrypto.EncryptedChunked,
                            onComplete: (@Sendable (URL) -> Void)? = nil) throws -> (MediaStream, URL) {
        var info = MediaInfo(type: "video", mediaId: "m1", key: enc.key.base64EncodedString(),
                             hash: enc.root.base64EncodedString(), size: plain.count, mime: "video/mp4")
        info.v = 2
        let final = dir.appendingPathComponent("m1.mp4")
        let stream = try MediaStream(media: info, fetchRange: server.fetch,
                                     partialURL: dir.appendingPathComponent("m1.partial"),
                                     finalURL: final, onComplete: onComplete)
        return (stream, final)
    }

    func testARangeIsServedWithoutTheWholeFile() async throws {
        let plain = plaintext(MediaCrypto.blockSize * 20 + 500)
        let enc = try MediaCrypto.encryptChunked(plain)
        let server = Server(enc.blob)
        let (stream, _) = try makeStream(plain, server: server, enc: enc)

        // the head, as playback starts
        let head = try await stream.plaintext(offset: 0, length: 1000)
        XCTAssertEqual(head, plain[0..<1000])
        XCTAssertLessThan(server.requested, enc.blob.count / 4)

        // and a seek far forward, which touches only the blocks it lands on
        let before = server.requested
        let seekOffset = MediaCrypto.blockSize * 15 + 77
        let middle = try await stream.plaintext(offset: seekOffset, length: 4096)
        XCTAssertEqual(middle, plain[seekOffset..<(seekOffset + 4096)])
        XCTAssertLessThan(server.requested - before, MediaCrypto.blockSize * 2 + 1024)
    }

    func testARangeAcrossBlocksIsWholeAndAskedForOnce() async throws {
        let plain = plaintext(MediaCrypto.blockSize * 3)
        let enc = try MediaCrypto.encryptChunked(plain)
        let server = Server(enc.blob)
        let (stream, _) = try makeStream(plain, server: server, enc: enc)
        let offset = MediaCrypto.blockSize - 10
        let data = try await stream.plaintext(offset: offset, length: MediaCrypto.blockSize + 20)
        XCTAssertEqual(data, Data(plain[offset..<(offset + MediaCrypto.blockSize + 20)]))
        let after = server.requested
        // the same range again is read from the blocks already opened
        _ = try await stream.plaintext(offset: offset, length: 128)
        XCTAssertEqual(server.requested, after)
    }

    func testTheFileLandsInTheCacheWhenEveryBlockIsIn() async throws {
        let plain = plaintext(MediaCrypto.blockSize * 5 + 33)
        let enc = try MediaCrypto.encryptChunked(plain)
        let server = Server(enc.blob)
        let done = expectation(description: "complete")
        let (stream, final) = try makeStream(plain, server: server, enc: enc) { _ in done.fulfill() }
        _ = try await stream.plaintext(offset: 0, length: plain.count)
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(try Data(contentsOf: final), plain)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("m1.partial").path))
    }

    func testTheBackgroundFillCompletesWhatPlaybackDidNotAskFor() async throws {
        let plain = plaintext(MediaCrypto.blockSize * 6 + 7)
        let enc = try MediaCrypto.encryptChunked(plain)
        let server = Server(enc.blob)
        let done = expectation(description: "complete")
        let (stream, final) = try makeStream(plain, server: server, enc: enc) { _ in done.fulfill() }
        _ = try await stream.plaintext(offset: 0, length: 512)
        stream.startBackgroundFill()
        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(try Data(contentsOf: final), plain)
    }

    func testATouchedByteBreaksItsBlockAndNothingElse() async throws {
        let plain = plaintext(MediaCrypto.blockSize * 3)
        let enc = try MediaCrypto.encryptChunked(plain)
        let server = Server(enc.blob)
        server.corruptAt = MediaCrypto.blockSize + MediaCrypto.tagSize + 5   // inside block 1
        let (stream, _) = try makeStream(plain, server: server, enc: enc)
        do {
            _ = try await stream.plaintext(offset: MediaCrypto.blockSize, length: 100)
            XCTFail("a block whose bytes were changed must not open")
        } catch {}
        server.corruptAt = nil
        let head = try await stream.plaintext(offset: 0, length: 100)
        XCTAssertEqual(head, plain[0..<100])
    }

    func testAnOlderFormatDoesNotStream() throws {
        let mm = MediaManager(api: APIClient(baseURL: URL(string: "http://localhost:1")!),
                              cacheDir: dir.appendingPathComponent("cache"))
        var v1 = MediaInfo(type: "video", mediaId: "old", key: "", hash: "", size: 10, mime: "video/mp4")
        XCTAssertNil(mm.stream(for: v1))
        v1.v = 2
        v1.mediaId = ""
        XCTAssertNil(mm.stream(for: v1))
    }
}
