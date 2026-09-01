import XCTest
import SwiftUI
@testable import Msngr

/// The floating tile of a call: where a drag may leave it, which side it is
/// released to, and how far a pinch may take its size.
final class FloatingTileTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
    private let size = CGSize(width: 100, height: 40)
    private let margin: CGFloat = 12

    func testTheTileStartsInTheCornerItIsGiven() {
        let point = FloatingTilePlacement.home(start: .topTrailing, margin: margin,
                                               in: bounds, size: size)
        XCTAssertEqual(point.x, 400 - 12 - 50)
        XCTAssertEqual(point.y, 12 + 20)
    }

    func testADragNeverTakesTheTileOutOfTheScreen() {
        let far = CGPoint(x: 5000, y: -5000)
        let placed = FloatingTilePlacement.clamp(far, margin: margin, in: bounds, size: size)
        XCTAssertEqual(placed.x, 400 - 12 - 50)
        XCTAssertEqual(placed.y, 12 + 20)
    }

    func testAReleasedTileGoesToTheSideItIsNearer() {
        let left = FloatingTilePlacement.snap(CGPoint(x: 120, y: 500), margin: margin,
                                              in: bounds, size: size)
        XCTAssertEqual(left.x, 12 + 50)
        XCTAssertEqual(left.y, 500, "the height it was left at is kept")

        let right = FloatingTilePlacement.snap(CGPoint(x: 260, y: 500), margin: margin,
                                               in: bounds, size: size)
        XCTAssertEqual(right.x, 400 - 12 - 50)
    }

    func testAPinchIsHeldBetweenItsTwoLimits() {
        XCTAssertEqual(FloatingTilePlacement.clamped(0.1), FloatingTilePlacement.minScale)
        XCTAssertEqual(FloatingTilePlacement.clamped(9), FloatingTilePlacement.maxScale)
        XCTAssertEqual(FloatingTilePlacement.clamped(1.25), 1.25)
    }

    /// A tile grown by a pinch is put back inside the screen, not left hanging
    /// over the edge it was standing against.
    func testAGrownTileIsPutBackInside() {
        let grown = CGSize(width: 300, height: 200)
        let corner = FloatingTilePlacement.home(start: .topTrailing, margin: margin,
                                                in: bounds, size: size)
        let placed = FloatingTilePlacement.clamp(corner, margin: margin,
                                                 in: bounds, size: grown)
        XCTAssertEqual(placed.x, 400 - 12 - 150)
        XCTAssertEqual(placed.y, 12 + 100)
    }
}
