import XCTest
@testable import MsngrCore

final class BlurHashTests: XCTestCase {
    // Diagonal gradient
    private func makeGradient(width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset + 0] = UInt8(x * 255 / (width - 1))
                pixels[offset + 1] = UInt8(y * 255 / (height - 1))
                pixels[offset + 2] = UInt8((x + y) * 255 / (width + height - 2))
            }
        }
        return pixels
    }

    private func averageRGB(_ pixels: [UInt8]) -> (Double, Double, Double) {
        var r = 0.0, g = 0.0, b = 0.0
        let count = pixels.count / 4
        for i in 0..<count {
            r += Double(pixels[i * 4 + 0])
            g += Double(pixels[i * 4 + 1])
            b += Double(pixels[i * 4 + 2])
        }
        return (r / Double(count), g / Double(count), b / Double(count))
    }

    func testRoundtrip() {
        let width = 32, height = 32
        let source = makeGradient(width: width, height: height)

        let hash = BlurHash.encode(pixels: source, width: width, height: height)
        XCTAssertNotNil(hash)
        guard let hash else { return }

        // 4x3 components: 1 (size) + 1 (maxAC) + 4 (DC) + 2*(4*3-1) (AC) = 28
        XCTAssertEqual(hash.count, 28)

        let decoded = BlurHash.decodePixels(hash, width: width, height: height)
        XCTAssertNotNil(decoded)
        guard let decoded else { return }
        XCTAssertEqual(decoded.count, width * height * 4)

        let (sr, sg, sb) = averageRGB(source)
        let (dr, dg, db) = averageRGB(decoded)
        XCTAssertEqual(sr, dr, accuracy: 25)
        XCTAssertEqual(sg, dg, accuracy: 25)
        XCTAssertEqual(sb, db, accuracy: 25)

        for i in 0..<(width * height) {
            XCTAssertEqual(decoded[i * 4 + 3], 255)
        }
    }

    func testDecodeInvalidHash() {
        XCTAssertNil(BlurHash.decodePixels("", width: 8, height: 8))
        XCTAssertNil(BlurHash.decodePixels("abc", width: 8, height: 8))
        // Valid prefix, but the length does not match the component count
        XCTAssertNil(BlurHash.decodePixels("LEHV6nWB2yk8", width: 8, height: 8))
        // Character outside the base83 alphabet
        XCTAssertNil(BlurHash.decodePixels(String(repeating: "!", count: 28), width: 8, height: 8))
    }

    func testEncodeInvalidInput() {
        XCTAssertNil(BlurHash.encode(pixels: [0, 0, 0], width: 32, height: 32))
        XCTAssertNil(BlurHash.encode(pixels: makeGradient(width: 8, height: 8), width: 8, height: 8, componentsX: 10))
    }
}
