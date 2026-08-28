import XCTest
import Metal
@testable import MsngrCore

/// Every shader in the gallery has to compile the way `ShaderProgram` builds
/// it: each pass through the transpiler and the Metal compiler into a pipeline
/// with the pass's own pixel format.
final class ShaderGalleryTests: XCTestCase {
    func testEveryGalleryShaderCompiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device on this host") }
        for doc in ShaderGallery.all {
            XCTAssertNotNil(doc.image, "\(doc.name ?? "?") has no image pass")
            for pass in doc.passes where pass.kind != .common {
                let msl = try ShaderTranspiler.transpile(pass.code, common: doc.common)
                let lib: MTLLibrary
                do {
                    lib = try device.makeLibrary(source: msl, options: nil)
                } catch {
                    XCTFail("\(doc.name ?? "?") / \(pass.id): \(error)")
                    continue
                }
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = lib.makeFunction(name: ShaderTranspiler.vertexFunction)
                desc.fragmentFunction = lib.makeFunction(name: ShaderTranspiler.fragmentFunction)
                desc.colorAttachments[0].pixelFormat = pass.kind == .image ? .bgra8Unorm : .rgba16Float
                XCTAssertNoThrow(try device.makeRenderPipelineState(descriptor: desc), "\(doc.name ?? "?") / \(pass.id)")
            }
        }
    }

    func testGalleryHashesAreDistinct() {
        let hashes = Set(ShaderGallery.all.map(\.contentHash))
        XCTAssertEqual(hashes.count, ShaderGallery.all.count)
    }

    func testStickersStayWithinTheMessageCeiling() {
        for doc in ShaderGallery.stickers {
            XCTAssertLessThan(doc.sourceBytes, ShaderTranspiler.maxSourceBytes / 4, doc.name ?? "?")
        }
    }
}
