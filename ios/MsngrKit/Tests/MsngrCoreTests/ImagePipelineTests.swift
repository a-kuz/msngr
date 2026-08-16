import XCTest
import CoreGraphics
import ImageIO
@testable import MsngrCore

final class ImagePipelineTests: XCTestCase {
    private var tempURL: URL!
    private var pngData: Data!

    override func setUpWithError() throws {
        pngData = try XCTUnwrap(Self.makePNG(width: 1000, height: 600))
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImagePipelineTests-\(UUID().uuidString).png")
        try pngData.write(to: tempURL)
    }

    override func tearDownWithError() throws {
        if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
    }

    /// A PNG drawn with CGContext: a solid background with a contrasting quadrant.
    private static func makePNG(width: Int, height: Int) -> Data? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    func testImageDownsamplesAndCaches() async throws {
        let pipeline = ImagePipeline()
        let target = CGSize(width: 300, height: 300)

        let decodedImage = await pipeline.image(at: tempURL, targetPixelSize: target)
        let image = try XCTUnwrap(decodedImage)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 300)
        // Aspect ratio is kept: 1000x600 -> 300x180.
        XCTAssertEqual(image.width, 300)
        XCTAssertEqual(image.height, 180)

        let cached = pipeline.cachedImage(at: tempURL, targetPixelSize: target)
        XCTAssertNotNil(cached)

        pipeline.clearMemory()
        XCTAssertNil(pipeline.cachedImage(at: tempURL, targetPixelSize: target))
    }

    func testPrepareForSendingProducesValidJPEG() throws {
        // 1000x600 is under the default 1280 limit, so a smaller limit is what actually shrinks it.
        let result = try XCTUnwrap(ImageProcessor.prepareForSending(pngData, maxDimension: 500))
        XCTAssertEqual(result.size, CGSize(width: 500, height: 300))

        // The result is a real JPEG: it decodes, and at the size we asked for.
        let source = try XCTUnwrap(CGImageSourceCreateWithData(result.data as CFData, nil))
        let type = try XCTUnwrap(CGImageSourceGetType(source) as String?)
        XCTAssertEqual(type, "public.jpeg")
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 500)
        XCTAssertEqual(decoded.height, 300)
    }

    func testPrepareForSendingDefaultLimit() throws {
        // The long side is 1000, under the 1280 limit, so nothing is upscaled.
        let result = try XCTUnwrap(ImageProcessor.prepareForSending(pngData))
        XCTAssertLessThanOrEqual(max(result.size.width, result.size.height), 1280)
    }

    func testRGBAPixelsSizeMatches() throws {
        let result = try XCTUnwrap(ImageProcessor.rgbaPixels(pngData))
        XCTAssertLessThanOrEqual(max(result.width, result.height), 32)
        XCTAssertEqual(result.pixels.count, result.width * result.height * 4)
    }
}
