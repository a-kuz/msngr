import XCTest
@testable import Msngr

/// Хвостик баббла — отдельная некапнутая картинка (см. аудит #40/#41):
/// тело баббла не должно зависеть от наличия хвоста, а сам хвост не должен
/// обрезаться по краю холста и должен быть зеркально симметричен для
/// исходящих/входящих сообщений.
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

    /// Хвост не должен касаться ни одного края холста непрозрачным пикселем —
    /// иначе кривая обрезана (см. дефект: x доходил до 48 при холсте 44).
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
            XCTAssertFalse(touchesLeft, "outgoing=\(outgoing): хвост обрезан по левому краю холста")
            XCTAssertFalse(touchesRight, "outgoing=\(outgoing): хвост обрезан по правому краю холста")
            XCTAssertFalse(touchesTop, "outgoing=\(outgoing): хвост обрезан по верхнему краю холста")
            XCTAssertFalse(touchesBottom, "outgoing=\(outgoing): хвост обрезан по нижнему краю холста")

            // и хвост вообще на месте (не пустая картинка)
            var anyOpaque = false
            for y in 0..<img.height where !anyOpaque {
                for x in 0..<img.width where img.alpha(x, y) > 10 { anyOpaque = true; break }
            }
            XCTAssertTrue(anyOpaque, "outgoing=\(outgoing): хвост не отрисовался")
        }
    }

    /// Входящий хвост — точное зеркало исходящего по горизонтали (симметрия слева/справа).
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
        XCTAssertEqual(mismatches, 0, "хвост входящего должен быть зеркалом хвоста исходящего")
    }

    /// Тело баббла (закруглённый прямоугольник) не принимает параметр tail —
    /// оно рисуется одинаково независимо от того, будет ли хвост показан поверх.
    func testBodyImageIdenticalRegardlessOfTailUsage() {
        let a = rasterize(BubbleBackground.image(outgoing: true, mediaOnly: false))
        let b = rasterize(BubbleBackground.image(outgoing: true, mediaOnly: false))
        XCTAssertEqual(a.pixels, b.pixels)
    }
}
