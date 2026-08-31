import XCTest
@testable import MsngrCore

/// The round video kind through the core: the push preview names it and the
/// gallery's media tab collects it.
final class RoundVideoKindTests: XCTestCase {
    func testPushPreviewNamesTheKind() {
        var payload = ContentPayload(kind: "roundVideo")
        payload.media = MediaInfo(type: "video", mediaId: "m", key: "k", hash: "h",
                                  size: 1, mime: "video/mp4")
        let preview = NotificationContentBuilder.preview(payload)
        XCTAssertTrue(preview.contains("📹"), "got: \(preview)")
        XCTAssertNotEqual(preview, NotificationContentBuilder.preview(ContentPayload(kind: "video")),
                          "a round video is named apart from a plain video")
    }

    func testGalleryMediaTabReadsRoundVideos() {
        XCTAssertTrue(GalleryTab.media.kinds.contains(.roundVideo))
    }

    func testKindRoundTripsThroughItsRawValue() {
        XCTAssertEqual(MessageKind(rawValue: "roundVideo"), .roundVideo)
        XCTAssertEqual(MessageKind.roundVideo.rawValue, "roundVideo")
    }
}
