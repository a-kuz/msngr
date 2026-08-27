import XCTest
import MsngrCore
@testable import Msngr

final class PickedBatchTests: XCTestCase {
    /// Photos and videos picked together travel as one album, each slot
    /// typed as what it will hold; a single video is a video message.
    func testMixedPickIsOneAlbumWithTypedSlots() {
        let items: [PickedBatch.Item] = [.photo, .video, .photo]
        XCTAssertEqual(PickedBatch.kind(of: items), .album)
        XCTAssertEqual(PickedBatch.blanks(for: items).map(\.type), ["photo", "video", "photo"])
        XCTAssertEqual(PickedBatch.blanks(for: items).map(\.mime), ["image/jpeg", "video/mp4", "image/jpeg"])
    }

    func testSinglePicksKeepTheirKind() {
        XCTAssertEqual(PickedBatch.kind(of: [.video]), .video)
        XCTAssertEqual(PickedBatch.kind(of: [.photo]), .photo)
        XCTAssertEqual(PickedBatch.kind(of: [.video, .video]), .album)
    }

    /// The progress store keys a slot by message and index; a single media
    /// message and slot 0 of an album share the same key shape.
    func testProgressKeysAndClearing() {
        let store = MediaProgress()
        store.set("m1", index: nil, fraction: 0.5)
        store.set("m1", index: 1, fraction: 0.25)
        store.set("m2", index: nil, fraction: 1)
        XCTAssertEqual(store.fraction("m1", index: 0), 0.5)
        XCTAssertEqual(store.fraction("m1", index: 1), 0.25)
        XCTAssertEqual(MediaProgress.key("m1", index: nil), MediaProgress.key("m1", index: 0))
        store.clear("m1")
        XCTAssertNil(store.fraction("m1", index: 0))
        XCTAssertNil(store.fraction("m1", index: 1))
        XCTAssertEqual(store.fraction("m2", index: nil), 1)
    }
}
