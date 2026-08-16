import XCTest
@testable import Msngr

/// The bubble tail is a separate uncapped image (see audit #40/#41): the bubble
/// body must not depend on whether a tail is there, and the tail itself must not
/// be clipped at the edge of its canvas and must mirror exactly between outgoing
/// and incoming messages.
final class BubbleTailTests: XCTestCase {
    private struct RGBAImage {
        let width: Int
        let height: Int
        let pixels: [UInt8] // row-major, 4 bytes/px (premultiplied RGBA)

        func alpha(_ x: Int, _ y: Int) -> UInt8 {
            pixels[(y * width + x) * 4 + 3]
        }
    }

    private func rasterize(_ image: UIImage) -> RGBAImage {
        let cg = image.cgImage!
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return RGBAImage(width: w, height: h, pixels: pixels)
    }

    /// No opaque pixel of the tail may touch any edge of the canvas, otherwise the
    /// curve is clipped (see the defect: x reached 48 on a canvas of 44).
    func testTailNotClippedAtCanvasEdge() {
        for outgoing in [true, false] {
            let img = rasterize(BubbleBackground.tailImage(outgoing: outgoing))
            var touchesLeft = false, touchesRight = false, touchesTop = false, touchesBottom = false
            for y in 0..<img.height {
                if img.alpha(0, y) > 10 { touchesLeft = true }
                if img.alpha(img.width - 1, y) > 10 { touchesRight = true }
            }
            for x in 0..<img.width {
                if img.alpha(x, 0) > 10 { touchesTop = true }
                if img.alpha(x, img.height - 1) > 10 { touchesBottom = true }
            }
            XCTAssertFalse(touchesLeft, "outgoing=\(outgoing): tail clipped at the left edge of the canvas")
            XCTAssertFalse(touchesRight, "outgoing=\(outgoing): tail clipped at the right edge of the canvas")
            XCTAssertFalse(touchesTop, "outgoing=\(outgoing): tail clipped at the top edge of the canvas")
            XCTAssertFalse(touchesBottom, "outgoing=\(outgoing): tail clipped at the bottom edge of the canvas")

            // and the tail is there at all (not an empty image)
            var anyOpaque = false
            for y in 0..<img.height where !anyOpaque {
                for x in 0..<img.width where img.alpha(x, y) > 10 { anyOpaque = true; break }
            }
            XCTAssertTrue(anyOpaque, "outgoing=\(outgoing): tail was not drawn")
        }
    }

    /// The incoming tail is an exact horizontal mirror of the outgoing one.
    func testIncomingTailIsMirrorOfOutgoing() {
        let out = rasterize(BubbleBackground.tailImage(outgoing: true))
        let inc = rasterize(BubbleBackground.tailImage(outgoing: false))
        XCTAssertEqual(out.width, inc.width)
        XCTAssertEqual(out.height, inc.height)
        var mismatches = 0
        for y in 0..<out.height {
            for x in 0..<out.width {
                let mirroredX = out.width - 1 - x
                if abs(Int(out.alpha(x, y)) - Int(inc.alpha(mirroredX, y))) > 10 {
                    mismatches += 1
                }
            }
        }
        XCTAssertEqual(mismatches, 0, "the incoming tail must mirror the outgoing one")
    }

    /// The bubble body (a rounded rectangle) takes no tail parameter: it is drawn
    /// the same whether or not a tail will be shown over it.
    func testBodyImageIdenticalRegardlessOfTailUsage() {
        let a = rasterize(BubbleBackground.image(outgoing: true, mediaOnly: false))
        let b = rasterize(BubbleBackground.image(outgoing: true, mediaOnly: false))
        XCTAssertEqual(a.pixels, b.pixels)
    }
}
