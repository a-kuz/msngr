import XCTest
import UIKit
@testable import Msngr

/// The story renderer bakes the canvas into the exported picture: what stands
/// behind a picture that does not fill the canvas, what a layer draws as, and
/// the size the export comes out at.
final class StoryRendererTests: XCTestCase {
    private let canvas = CGSize(width: 402, height: 874)

    private func solid(_ color: UIColor, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func pixel(_ image: UIImage, at point: CGPoint) -> (r: UInt8, g: UInt8, b: UInt8) {
        guard let cg = image.cgImage else { return (0, 0, 0) }
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: -point.x, y: -(CGFloat(cg.height) - point.y - 1),
                                width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return (data[0], data[1], data[2])
    }

    /// The brightest pixel along one row, as the sum of its channels, and the
    /// largest red channel there.
    private func row(_ image: UIImage, y: CGFloat) -> (brightest: Int, red: Int) {
        guard let cg = image.cgImage else { return (0, 0) }
        let width = cg.width
        var data = [UInt8](repeating: 0, count: width * 4)
        let ctx = CGContext(data: &data, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: -(CGFloat(cg.height) - y - 1),
                                width: CGFloat(cg.width), height: CGFloat(cg.height)))
        var brightest = 0, red = 0
        for x in 0..<width {
            let r = Int(data[x * 4]), g = Int(data[x * 4 + 1]), b = Int(data[x * 4 + 2])
            brightest = max(brightest, r + g + b)
            red = max(red, r)
        }
        return (brightest, red)
    }

    func testExportSizeKeepsTheCanvasShapeAtTheExportWidth() {
        let size = StoryRenderer.exportSize(for: canvas)
        XCTAssertEqual(size.width, 1080)
        XCTAssertEqual(size.height.truncatingRemainder(dividingBy: 2), 0)
        XCTAssertEqual(size.height / size.width, canvas.height / canvas.width, accuracy: 0.01)
    }

    func testBackdropIsBuiltFromThePicture() {
        let backdrop = StoryRenderer.backdrop(solid(.red, size: CGSize(width: 400, height: 200)),
                                              size: canvas)
        XCTAssertNotNil(backdrop)
        guard let backdrop else { return }
        let middle = row(backdrop, y: backdrop.size.height / 2)
        XCTAssertGreaterThan(middle.red, 150, "a blurred red picture stays red, got \(middle)")
    }

    /// A wide picture leaves the top of the canvas to the blurred copy of
    /// itself, never to black bars.
    func testAWidePictureStandsOverItsOwnBlur() {
        let frame = StoryFrame(image: solid(.red, size: CGSize(width: 400, height: 200)), isVideo: false)
        let out = StoryRenderer.renderPhoto(frame, canvas: canvas)
        let top = row(out, y: 20)
        XCTAssertGreaterThan(top.red, 60, "the backdrop should carry the picture's colour, got \(top)")
        let middle = pixel(out, at: CGPoint(x: out.size.width / 2, y: out.size.height / 2))
        XCTAssertGreaterThan(Int(middle.r), 200)
        XCTAssertLessThan(Int(middle.g), 30)
    }

    func testLayersAndStrokesAreBakedIn() {
        var frame = StoryFrame(image: solid(.black, size: CGSize(width: 400, height: 870)), isVideo: false)
        frame.strokes = [StoryStroke(brush: .pen, color: "#00ff00", width: 0.05,
                                     points: [CGPoint(x: 0.1, y: 0.8), CGPoint(x: 0.9, y: 0.8)])]
        var layer = StoryLayer(kind: .text("Hello"))
        layer.color = "#ff0000"
        layer.plate = .light
        layer.center = CGPoint(x: 0.5, y: 0.3)
        frame.layers = [layer]
        let out = StoryRenderer.renderPhoto(frame, canvas: canvas)
        let onStroke = pixel(out, at: CGPoint(x: out.size.width / 2, y: out.size.height * 0.8))
        XCTAssertGreaterThan(Int(onStroke.g), 200, "the stroke should be green, got \(onStroke)")
        let acrossPlate = row(out, y: out.size.height * 0.3)
        XCTAssertGreaterThan(acrossPlate.brightest, 450,
                             "the light plate should lift the black, got \(acrossPlate)")
    }

    func testALayerImageIsNeverEmptyAndScalesWithTheLayer() {
        var layer = StoryLayer(kind: .text("Scale"))
        let small = StoryRenderer.image(for: layer, canvasWidth: 402)
        layer.scale = 2
        let big = StoryRenderer.image(for: layer, canvasWidth: 402)
        XCTAssertGreaterThan(small.size.width, 10)
        XCTAssertGreaterThan(big.size.width, small.size.width * 1.7)
        let emoji = StoryRenderer.image(for: StoryLayer(kind: .emoji("🔥")), canvasWidth: 402)
        XCTAssertGreaterThan(emoji.size.height, 60)
    }
}
