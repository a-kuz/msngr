import XCTest
import CoreGraphics
@testable import MsngrCore

final class AlbumMosaicTests: XCTestCase {

    private let maxWidth: CGFloat = 320
    private let spacing: CGFloat = 2

    // Fixed aspect-ratio sets for n = 1...10.
    private let fixtures: [[CGFloat]] = [
        [1.33],
        [0.7, 0.7],
        [0.8, 1.0, 1.2],
        [1.5, 0.9, 1.1, 0.75],
        [1.0, 1.0, 1.0, 1.0, 1.0],
        [1.78, 0.56, 1.0, 1.33, 0.75, 1.0],
        [0.7, 1.5, 1.0, 0.9, 1.2, 0.8, 1.1],
        [1.0, 1.33, 0.75, 1.78, 0.56, 1.0, 1.2, 0.9],
        [1.2, 0.8, 1.0, 1.5, 0.7, 1.1, 0.9, 1.33, 1.0],
        [1.0, 0.7, 1.78, 1.2, 0.9, 1.1, 0.56, 1.33, 0.8, 1.0],
    ]

    func testLayoutInvariantsForAllCounts() {
        for aspects in fixtures {
            let items = aspects.map(MosaicItem.init(aspect:))
            let (rects, size) = AlbumMosaic.layout(items: items, maxWidth: maxWidth, spacing: spacing)
            let label = "n=\(aspects.count)"

            XCTAssertEqual(rects.count, aspects.count, label)
            XCTAssertEqual(Set(rects.map(\.index)), Set(0..<aspects.count), label)
            XCTAssertEqual(size.width, maxWidth, accuracy: 0.5, label)
            XCTAssertGreaterThan(size.height, 0, label)

            // Every tile stays inside the container (0.5pt tolerance).
            let container = CGRect(origin: .zero, size: size)
            for r in rects {
                XCTAssertTrue(container.insetBy(dx: -0.5, dy: -0.5).contains(r.frame),
                              "\(label): tile \(r.index) outside the container \(r.frame) / \(size)")
            }

            // No two tiles overlap (0.5pt tolerance).
            for i in rects.indices {
                for j in rects.indices where j > i {
                    let a = rects[i].frame.insetBy(dx: 0.25, dy: 0.25)
                    let b = rects[j].frame.insetBy(dx: 0.25, dy: 0.25)
                    XCTAssertFalse(a.intersects(b),
                                   "\(label): tiles \(rects[i].index) and \(rects[j].index) overlap")
                }
            }

            // No holes: the uncovered area is only the gaps, at most 2% of the container.
            let containerArea = size.width * size.height
            let tilesArea = rects.reduce(CGFloat(0)) { $0 + $1.frame.width * $1.frame.height }
            XCTAssertLessThanOrEqual(containerArea - tilesArea, containerArea * 0.02,
                                     "\(label): holes in the layout, covered \(tilesArea / containerArea)")

            // Every row, meaning every group of tiles sharing a minY, reaches the right edge.
            var rowsByY: [Int: CGFloat] = [:]
            for r in rects {
                let key = Int((r.frame.minY * 2).rounded())
                rowsByY[key] = max(rowsByY[key] ?? 0, r.frame.maxX)
            }
            for (y, maxX) in rowsByY {
                XCTAssertEqual(maxX, maxWidth, accuracy: 0.5,
                               "\(label): row y=\(CGFloat(y) / 2) stops short of the right edge")
            }
        }
    }

    func testTwoPortraitsSideBySide() {
        let items = [MosaicItem(aspect: 0.7), MosaicItem(aspect: 0.7)]
        let (rects, _) = AlbumMosaic.layout(items: items, maxWidth: maxWidth, spacing: spacing)
        XCTAssertEqual(rects.count, 2)
        for r in rects {
            XCTAssertEqual(r.frame.minY, 0, "portraits should stand side by side")
        }
    }
}
