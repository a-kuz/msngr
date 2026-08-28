import XCTest
import Metal
@testable import MsngrCore

/// The transpiler is exercised on real Shadertoy-dialect sources, and the MSL
/// it emits is compiled by the host's Metal compiler: a translation that only
/// looks right is worth nothing, the compiler is the judge.
final class ShaderTranspilerTests: XCTestCase {
    static let device = MTLCreateSystemDefaultDevice()

    /// Compiles one pass and returns the MSL, or fails the test with the
    /// compiler's own message and the emitted source for reading.
    @discardableResult
    func compile(_ glsl: String, common: String = "", file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let msl = try ShaderTranspiler.transpile(glsl, common: common)
        guard let device = Self.device else { throw XCTSkip("no Metal device on this host") }
        do {
            let lib = try device.makeLibrary(source: msl, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: ShaderTranspiler.vertexFunction)
            desc.fragmentFunction = lib.makeFunction(name: ShaderTranspiler.fragmentFunction)
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            _ = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            XCTFail("MSL did not compile: \(error)\n--- emitted ---\n\(msl)", file: file, line: line)
        }
        return msl
    }

    func fixture(_ name: String, ext: String = "glsl") throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: the owner's samples

    func testMacPaintSampleCompiles() throws {
        let doc = try ShaderDocument.parse(try fixture("macpaint"))
        XCTAssertEqual(doc.passes.count, 1)
        XCTAssertEqual(doc.image?.inputs.map(\.source), ["noise", "graynoise", "noise64", "buffer:image"])
        let msl = try compile(doc.image!.code)
        // lookup tables are hoisted as constant globals, not per-thread copies
        XCTAssertTrue(msl.contains("constant int FONT_ROWS[] = {"))
        XCTAssertTrue(msl.contains("constant float2 PTS[] = {"))
        XCTAssertTrue(msl.contains("constant float LOOP = 44.0;"))
        XCTAssertTrue(msl.contains("void mainImage(thread float4& O, float2 F)"))
    }

    func testFlowerEveningExportCompilesBothPasses() throws {
        let doc = try ShaderDocument.parse(try fixture("flower-evening.shadertoy", ext: "json"))
        XCTAssertEqual(doc.name, "flower evening")
        XCTAssertEqual(doc.passes.map(\.id), ["A", "image"])
        // Buffer A reads itself (the previous frame), Image reads Buffer A
        XCTAssertEqual(doc.passes[0].input(0).source, "buffer:A")
        XCTAssertEqual(doc.passes[0].input(0).wrap, "clamp")
        XCTAssertEqual(doc.image?.input(0).source, "buffer:A")
        XCTAssertEqual(doc.image?.input(1).source, "none")
        for pass in doc.passes { try compile(pass.code, common: doc.common) }
    }

    // MARK: dialect probes

    func testMinimalShader() throws {
        try compile("""
        void mainImage(out vec4 fragColor, in vec2 fragCoord) {
            vec2 uv = fragCoord / iResolution.xy;
            fragColor = vec4(uv, 0.5 + 0.5 * sin(iTime), 1.0);
        }
        """)
    }

    func testCommentsDirectivesAndPrecision() throws {
        try compile("""
        #version 300 es
        precision highp float;
        #pragma msngr channel0 prevframe
        // a comment with mainImage( in it
        /* block
           comment */
        #define TAU 6.2831
        void mainImage(out vec4 O, in vec2 F) { O = vec4(sin(TAU * F.x / iResolution.x)); }
        """)
    }

    func testCommonCodeIsSharedByThePass() throws {
        try compile("void mainImage(out vec4 O, in vec2 F) { O = vec4(palette(iTime), 1.0); }",
                    common: "vec3 palette(float t) { return 0.5 + 0.5 * cos(t + vec3(0, 2, 4)); }")
    }

    func testHelpersCallEachOtherOutOfOrder() throws {
        // a struct member may be used before its definition, unlike GLSL
        try compile("""
        vec3 palette(float t);
        void mainImage(out vec4 O, in vec2 F) { O = vec4(palette(iTime), 1.0); }
        vec3 palette(float t) { return 0.5 + 0.5 * cos(t + vec3(0, 2, 4)) * glow(t); }
        float glow(float t) { return fract(t); }
        """)
    }

    func testUniformsVisibleInHelpers() throws {
        try compile("""
        float pulse() { return 0.5 + 0.5 * sin(iTime * 3.0) * float(iFrame % 2) + iTimeDelta + iDate.w + iMouse.x; }
        void mainImage(out vec4 O, in vec2 F) { O = vec4(pulse()); }
        """)
    }

    func testOutInoutParameters() throws {
        try compile("""
        void split(in vec2 p, out float a, inout float b) { a = p.x; b += p.y; }
        void mainImage(out vec4 O, in vec2 F) {
            float a; float b = 1.0;
            split(F, a, b);
            O = vec4(a, b, 0.0, 1.0);
        }
        """)
    }

    func testArrayConstructorsAndLength() throws {
        try compile("""
        const vec3 COLORS[3] = vec3[3](vec3(1,0,0), vec3(0,1,0), vec3(0,0,1));
        void mainImage(out vec4 O, in vec2 F) {
            float w[] = float[](0.2, 0.3, 0.5);
            int i = int(F.x) % COLORS.length();
            O = vec4(COLORS[i] * w[i % w.length()], 1.0);
        }
        """)
    }

    func testModAtanInverseAndBroadcastOverloads() throws {
        try compile("""
        void mainImage(out vec4 O, in vec2 F) {
            vec2 uv = F / iResolution.xy;
            float a = atan(uv.y, uv.x);
            vec3 c = mod(vec3(a) + iTime, 6.2831);
            c = clamp(c, 0.0, 1.0);
            c = min(c, 0.9); c = max(c, 0.1);
            c = smoothstep(0.1, 0.9, c);
            c = pow(c, 2.2);
            mat2 m = inverse(mat2(cos(a), sin(a), -sin(a), cos(a)));
            mat3 m3 = inverse(mat3(1.0));
            mat4 m4 = inverse(mat4(1.0));
            uv = m * uv;
            vec3 d = radians(degrees(c)) * inversesqrt(c + 1.0);
            O = vec4(c + d + m3[0] + m4[0].xyz + step(0.5, c) + mix(c, d, 0.5), 1.0) * mod(uv.x, 1.0);
        }
        """)
    }

    func testTexturesOnChannels() throws {
        try compile("""
        void mainImage(out vec4 O, in vec2 F) {
            vec2 uv = F / iResolution.xy;
            vec4 n = texture(iChannel0, uv * 4.0);
            float g = textureLod(iChannel1, uv, 0.0).r;
            vec4 f = texelFetch(iChannel2, ivec2(F) % textureSize(iChannel2, 0), 0);
            vec4 prev = texture(iChannel3, uv);
            O = mix(prev, n * g + f, 0.1) + iChannelResolution[0].x * 0.0 + iChannelTime[1];
        }
        """)
    }

    func testReservedIdentifiersAreRenamed() throws {
        try compile("""
        float half = 0.5;
        vec3 vertex(vec3 p) { return p * half; }
        void mainImage(out vec4 O, in vec2 F) {
            float thread = 1.0; int template = 2; float constant = 3.0;
            O = vec4(vertex(vec3(F, thread)) * float(template) * constant, 1.0);
        }
        """)
    }

    func testMutableGlobalAndUserStruct() throws {
        try compile("""
        struct Ray { vec3 o; vec3 d; };
        vec3 gLight = vec3(0.0, 1.0, 0.0);
        float march(Ray r) { gLight += r.d * 0.001; return length(r.o) - 1.0; }
        void mainImage(out vec4 O, in vec2 F) {
            Ray r = Ray(vec3(0.0, 0.0, -3.0), normalize(vec3(F / iResolution.xy - 0.5, 1.0)));
            O = vec4(march(r) + gLight, 1.0);
        }
        """)
    }

    func testSwitchBitOpsIntegerVectorsAndDiscard() throws {
        try compile("""
        void mainImage(out vec4 O, in vec2 F) {
            ivec2 p = ivec2(floor(F));
            uint h = uint(p.x) * 747796405u + 2891336453u;
            h ^= h >> 16u;
            int sel = (p.x + p.y) & 3;
            float v;
            switch (sel) { case 0: v = 0.1; break; case 1: v = 0.4; break; default: v = 0.9; }
            if (p.y < 0) discard;
            bvec2 b = lessThan(F, iResolution.xy * 0.5);
            O = vec4(v, float(h & 255u) / 255.0, any(b) ? 1.0 : 0.0, 1.0);
        }
        """)
    }

    // MARK: the document

    func testPragmaRebindsChannels() throws {
        let doc = try ShaderDocument.parse("""
        #pragma msngr channel0 prevframe
        #pragma msngr channel1 none
        void mainImage(out vec4 O, in vec2 F) { O = texture(iChannel0, F / iResolution.xy) * 0.99; }
        """)
        XCTAssertEqual(doc.image?.inputs.map(\.source), ["buffer:image", "none", "noise64", "buffer:image"])
    }

    func testDocumentRoundTripsThroughJSON() throws {
        let doc = try ShaderDocument.parse(try fixture("flower-evening.shadertoy", ext: "json"))
        let data = try JSONEncoder().encode(doc)
        XCTAssertEqual(try JSONDecoder().decode(ShaderDocument.self, from: data), doc)
    }

    // MARK: refusals

    func testNoMainImage() {
        XCTAssertThrowsError(try ShaderTranspiler.transpile("void main() {}")) { error in
            XCTAssertEqual(error as? ShaderTranspiler.Failure, .noMainImage)
        }
        XCTAssertThrowsError(try ShaderDocument.parse("hello there")) { error in
            XCTAssertEqual(error as? ShaderDocument.Failure, .notAShader)
        }
    }

    func testTooLarge() {
        let big = String(repeating: "// x\n", count: ShaderTranspiler.maxSourceBytes / 5 + 1)
            + "void mainImage(out vec4 O, in vec2 F) {}"
        XCTAssertThrowsError(try ShaderDocument.parse(big)) { error in
            guard case ShaderDocument.Failure.tooLarge = error else { return XCTFail("\(error)") }
        }
    }

    func testSoundAndCubemapsRefused() {
        XCTAssertThrowsError(try ShaderTranspiler.transpile("vec2 mainSound(int s, float t) { return vec2(0); } void mainImage(out vec4 O, in vec2 F) {}"))
        XCTAssertThrowsError(try ShaderTranspiler.transpile("uniform samplerCube c; void mainImage(out vec4 O, in vec2 F) {}"))
    }
}
