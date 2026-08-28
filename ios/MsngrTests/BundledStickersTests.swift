import XCTest
import Metal
import MsngrCore
@testable import Msngr

/// The bundled stickers have to compile on the device they ship to: every pass
/// through the transpiler and the Metal compiler into a pipeline, the way
/// `ShaderProgram` builds them.
final class BundledStickersTests: XCTestCase {
    func testEveryBundledStickerCompiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        XCTAssertEqual(ShaderStickers.bundled.count, 4)
        for doc in ShaderStickers.bundled {
            for pass in doc.passes where pass.kind != .common {
                let msl = try ShaderTranspiler.transpile(pass.code, common: doc.common)
                let lib: MTLLibrary
                do {
                    lib = try device.makeLibrary(source: msl, options: nil)
                } catch {
                    XCTFail("\(doc.name ?? "?") / \(pass.id): \(ShaderProgram.firstLine(of: error))")
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

    func testBundledStickersHaveDistinctHashes() {
        let hashes = Set(ShaderStickers.bundled.map(\.contentHash))
        XCTAssertEqual(hashes.count, ShaderStickers.bundled.count)
    }
}
