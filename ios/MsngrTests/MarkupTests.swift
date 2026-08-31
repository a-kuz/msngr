import XCTest
@testable import Msngr

final class MarkupTests: XCTestCase {
    // MARK: - Helpers

    private func image(size: CGSize, draw: (CGContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            draw(ctx.cgContext)
        }
    }

    private func pixel(_ image: UIImage, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        guard let cg = image.cgImage else { XCTFail("no cgImage"); return (0, 0, 0) }
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: -x, y: y - cg.height + 1, width: cg.width, height: cg.height))
        return (data[0], data[1], data[2])
    }

    private func blackWithWhiteCorner(_ size: CGSize) -> UIImage {
        image(size: size) { ctx in
            ctx.setFillColor(UIColor.black.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 6, height: 6))
        }
    }

    // MARK: - History

    func testHistoryUndoRedo() {
        var h = MarkupHistory()
        XCTAssertFalse(h.canUndo)
        var doc = MarkupDocument()
        doc.rotationQuarters = 1
        h.push(doc)
        doc.rotationQuarters = 2
        h.push(doc)
        XCTAssertEqual(h.current.rotationQuarters, 2)
        h.undo()
        XCTAssertEqual(h.current.rotationQuarters, 1)
        XCTAssertTrue(h.canRedo)
        h.redo()
        XCTAssertEqual(h.current.rotationQuarters, 2)
        h.undo()
        doc.rotationQuarters = 3
        h.push(doc)
        XCTAssertFalse(h.canRedo, "a new step drops the redo branch")
        h.undo()
        h.undo()
        XCTAssertEqual(h.current.rotationQuarters, 0)
        XCTAssertFalse(h.canUndo)
    }

    // MARK: - Rotation geometry

    func testRotationRoundTrip() {
        let baseSize = CGSize(width: 40, height: 20)
        let p = CGPoint(x: 7, y: 13)
        for quarters in 0...3 {
            var doc = MarkupDocument()
            doc.rotationQuarters = quarters
            let there = doc.fromBase(p, baseSize: baseSize)
            let back = doc.toBase(there, baseSize: baseSize)
            XCTAssertEqual(back.x, p.x, accuracy: 0.001, "quarters \(quarters)")
            XCTAssertEqual(back.y, p.y, accuracy: 0.001, "quarters \(quarters)")
        }
    }

    func testClockwiseTurnMovesTopLeftToTopRight() {
        var doc = MarkupDocument()
        doc.rotationQuarters = 1
        let rendered = MarkupRenderer.render(base: blackWithWhiteCorner(CGSize(width: 40, height: 20)),
                                             document: doc)
        XCTAssertEqual(rendered.size.width, 20)
        XCTAssertEqual(rendered.size.height, 40)
        let corner = pixel(rendered, 17, 2)
        XCTAssertGreaterThan(corner.r, 200, "the white corner turns into the top-right")
        let opposite = pixel(rendered, 2, 37)
        XCTAssertLessThan(opposite.r, 50)
    }

    // MARK: - Crop

    func testCropCutsToTheRectangle() {
        var doc = MarkupDocument()
        doc.crop = CGRect(x: 5, y: 4, width: 10, height: 8)
        let rendered = MarkupRenderer.render(base: blackWithWhiteCorner(CGSize(width: 40, height: 20)),
                                             document: doc)
        XCTAssertEqual(rendered.size.width, 10)
        XCTAssertEqual(rendered.size.height, 8)
    }

    // MARK: - Blur

    func testBlurSoftensTheRegionAndSparesTheRest() {
        let base = image(size: CGSize(width: 60, height: 30)) { ctx in
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 30, height: 30))
            ctx.setFillColor(UIColor.black.cgColor)
            ctx.fill(CGRect(x: 30, y: 0, width: 30, height: 30))
        }
        var doc = MarkupDocument()
        doc.strokes.append(MarkupStroke(tool: .blur, color: .clear, width: 0,
                                        points: [CGPoint(x: 20, y: 5), CGPoint(x: 40, y: 25)]))
        let rendered = MarkupRenderer.render(base: base, document: doc)
        let onEdge = pixel(rendered, 30, 15)
        XCTAssertTrue(onEdge.r > 40 && onEdge.r < 215, "the sharp edge inside the region turns gray, got \(onEdge)")
        let farLeft = pixel(rendered, 5, 15)
        XCTAssertGreaterThan(farLeft.r, 240, "outside the region the picture stays")
        let farRight = pixel(rendered, 55, 15)
        XCTAssertLessThan(farRight.r, 15)
    }

    // MARK: - Strokes land

    func testArrowLeavesInk() {
        var doc = MarkupDocument()
        doc.strokes.append(MarkupStroke(tool: .arrow, color: .red, width: 3,
                                        points: [CGPoint(x: 5, y: 15), CGPoint(x: 55, y: 15)]))
        let rendered = MarkupRenderer.render(base: image(size: CGSize(width: 60, height: 30)) { ctx in
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 30))
        }, document: doc)
        let mid = pixel(rendered, 30, 15)
        XCTAssertGreaterThan(mid.r, 180)
        XCTAssertLessThan(mid.g, 120)
    }

    func testTextLeavesInkAndReportsBounds() {
        let stroke = MarkupStroke(tool: .text, color: .red, width: 0,
                                  points: [CGPoint(x: 4, y: 8)], text: "hi", fontSize: 16)
        let bounds = MarkupRenderer.textBounds(stroke)
        XCTAssertGreaterThan(bounds.width, 4)
        XCTAssertGreaterThan(bounds.height, 10)
        var doc = MarkupDocument()
        doc.strokes.append(stroke)
        let rendered = MarkupRenderer.render(base: image(size: CGSize(width: 60, height: 40)) { ctx in
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        }, document: doc)
        var inked = false
        for x in stride(from: 4, to: 30, by: 2) {
            for y in stride(from: 8, to: 30, by: 2) where pixel(rendered, x, y).g < 200 {
                inked = true
            }
        }
        XCTAssertTrue(inked, "the label leaves visible pixels")
    }

    // MARK: - Preview scale

    func testPreviewScaleShrinksProportionally() {
        let rendered = MarkupRenderer.render(base: blackWithWhiteCorner(CGSize(width: 40, height: 20)),
                                             document: MarkupDocument(), scale: 0.5)
        XCTAssertEqual(rendered.size.width, 20)
        XCTAssertEqual(rendered.size.height, 10)
    }

    // MARK: - The straightening gesture

    func testStraightDragIsRecognized() {
        let straight = stride(from: 0, through: 100, by: 5).map {
            CGPoint(x: CGFloat($0), y: CGFloat($0) * 0.5 + CGFloat.random(in: -3...3))
        }
        XCTAssertTrue(MarkupCanvasView.isStraight(straight))
    }

    func testScribbleIsNotStraightened() {
        let zigzag = stride(from: 0, through: 100, by: 5).map {
            CGPoint(x: CGFloat($0), y: $0 % 10 == 0 ? 40 : 0)
        }
        XCTAssertFalse(MarkupCanvasView.isStraight(zigzag))
        let short = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)]
        XCTAssertFalse(MarkupCanvasView.isStraight(short), "a short chord is a dot, not a line")
    }
}
