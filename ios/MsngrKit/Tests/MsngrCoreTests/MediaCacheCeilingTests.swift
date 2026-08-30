import XCTest
@testable import MsngrCore

/// The decrypted media cache stays under its ceiling: the files untouched the
/// longest go first, and a cache hit counts as a touch.
final class MediaCacheCeilingTests: XCTestCase {
    private var dir: URL!
    private var media: MediaManager!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-test-\(UUID().uuidString)")
        media = MediaManager(api: APIClient(baseURL: URL(string: "http://localhost:1")!),
                             cacheDir: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func seed(_ mediaId: String, bytes: Int, daysOld: Double) throws {
        try media.seedCache(mediaId: mediaId, mime: "image/jpeg",
                            data: Data(repeating: 7, count: bytes))
        let url = dir.appendingPathComponent("\(mediaId).jpg")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-daysOld * 86_400)],
            ofItemAtPath: url.path)
    }

    func testOldestFilesGoFirstUntilTheCeilingHolds() throws {
        try seed("old", bytes: 4_000, daysOld: 3)
        try seed("mid", bytes: 4_000, daysOld: 2)
        try seed("new", bytes: 4_000, daysOld: 0)
        media.cacheCeilingBytes = 9_000
        media.enforceCacheCeiling()
        XCTAssertNil(media.cachedURL(for: "old", mime: "image/jpeg"))
        // dropping "old" lands at 8000, inside the 90% target of 8100 — enough
        XCTAssertNotNil(media.cachedURL(for: "mid", mime: "image/jpeg"))
        XCTAssertNotNil(media.cachedURL(for: "new", mime: "image/jpeg"))
        XCTAssertLessThanOrEqual(media.totalCacheSize(), 9_000)
    }

    func testZeroCeilingMeansUnbounded() throws {
        try seed("a", bytes: 10_000, daysOld: 1)
        media.cacheCeilingBytes = 0
        media.enforceCacheCeiling()
        XCTAssertNotNil(media.cachedURL(for: "a", mime: "image/jpeg"))
    }

    /// Opening a file saves it: the hit refreshes its date, so eviction takes
    /// the one that was merely downloaded earlier but never looked at.
    func testAHitRefreshesTheFileAgainstEviction() throws {
        try seed("touched", bytes: 4_000, daysOld: 3)
        try seed("ignored", bytes: 4_000, daysOld: 2)
        _ = media.cachedURL(for: "touched", mime: "image/jpeg")
        media.cacheCeilingBytes = 6_000
        media.enforceCacheCeiling()
        XCTAssertNotNil(media.cachedURL(for: "touched", mime: "image/jpeg"))
        XCTAssertNil(media.cachedURL(for: "ignored", mime: "image/jpeg"))
    }

    func testUnderTheCeilingNothingIsTouched() throws {
        try seed("a", bytes: 1_000, daysOld: 5)
        try seed("b", bytes: 1_000, daysOld: 1)
        media.cacheCeilingBytes = 10_000
        media.enforceCacheCeiling()
        XCTAssertEqual(media.totalCacheSize(), 2_000)
    }
}
