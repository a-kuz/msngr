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

    // MARK: the device as input

    func testDeviceUniformsAreVisible() throws {
        try compile("""
        void mainImage(out vec4 O, in vec2 F) {
            vec3 g = iGyro + iAccel + iGravity + iMagnet;
            vec4 q = iAttitude + iLocation + iPencil + iBubble;
            float f = iPressure + iAltitude + iProximity + iBattery + float(iBatteryState)
                    + iDark + iTextScale + iPencilAzimuth + iPencilHover + iScroll + iScreen.x;
            vec4 t = iTouch[0] + iTouch[4];
            vec4 c = iAccent + iBackground + iBubbleIn + iBubbleOut + iLabel;
            O = vec4(g, f) + q + t + c;
        }
        """)
    }

    func testUniformBlockMatchesTheSlots() {
        // the MSL struct is laid out slot by slot; the stride must hold every slot
        XCTAssertEqual(ShaderTranspiler.Uniform.allCases.count * 16, 480)
        XCTAssertLessThanOrEqual(ShaderTranspiler.Uniform.allCases.count * 16, ShaderTranspiler.uniformStride)
        XCTAssertEqual(ShaderTranspiler.Uniform.label.offset, 464)
        // the emitted struct names the same fields in the same order
        let fields = ["timeFrame", "resolution", "mouse", "date", "channelResolution[4]", "touch[5]",
                      "gyro", "accel", "gravity", "magnet", "attitude", "location", "environment",
                      "deviceState", "pencil", "pencilMore", "bubble", "screen", "accent", "background",
                      "bubbleIn", "bubbleOut", "label"]
        var last = ShaderTranspiler.prelude.startIndex
        for f in fields {
            let r = ShaderTranspiler.prelude.range(of: "float4 \(f);", range: last..<ShaderTranspiler.prelude.endIndex)
            XCTAssertNotNil(r, "\(f) missing or out of order in MsngrShaderUniforms")
            if let r { last = r.upperBound }
        }
    }

    func testLivePragmasAndHaptics() throws {
        let doc = ShaderDocument.fromGLSL("""
        #pragma msngr channel0 mic
        #pragma msngr channel1 camera:front
        #pragma msngr channel2 keyboard
        #pragma msngr haptics
        void mainImage(out vec4 O, in vec2 F) {
            float fft = texture(iChannel0, vec2(F.x / iResolution.x, 0.25)).x;
            vec4 cam = texture(iChannel1, F / iResolution.xy);
            float key = texelFetch(iChannel2, ivec2(32, 0), 0).x;
            O = vec4(fft, key, 0.0, 1.0) + cam;
            if (F.x < 1.0 && F.y < 1.0) O = vec4(fft, 0.5, 0.0, 1.0);
        }
        """)
        XCTAssertEqual(doc.image?.input(0).source, ShaderInput.mic)
        XCTAssertEqual(doc.image?.input(1).source, ShaderInput.cameraFront)
        XCTAssertEqual(doc.image?.input(2).source, ShaderInput.keyboard)
        XCTAssertEqual(doc.image?.input(0).wrap, "clamp")
        XCTAssertEqual(doc.haptics, true)
        XCTAssertEqual(doc.liveSources, [ShaderInput.mic, ShaderInput.cameraFront, ShaderInput.keyboard])
        XCTAssertTrue(doc.references("iResolution"))
        XCTAssertFalse(doc.references("iGyro"))
        try compile(doc.image!.code)
    }

    func testShadertoyLiveInputsMapToTheDevice() throws {
        let json = """
        {"ver":"0.1","info":{"name":"live"},"renderpass":[{"name":"Image","type":"image",
         "code":"void mainImage(out vec4 O, in vec2 F){O=texture(iChannel0,F/iResolution.xy)+texture(iChannel1,F/iResolution.xy)+texelFetch(iChannel2,ivec2(0),0);}",
         "inputs":[{"id":"a","type":"mic","channel":0},{"id":"b","type":"webcam","channel":1},{"id":"c","type":"keyboard","channel":2}],
         "outputs":[{"id":"o","channel":0}]}]}
        """
        let doc = try ShaderDocument.parse(json)
        XCTAssertEqual(doc.image?.inputs.map(\.source), [ShaderInput.mic, ShaderInput.camera, ShaderInput.keyboard])
        try compile(doc.image!.code)
    }

    func testContentHashIgnoresTheName() throws {
        var a = ShaderDocument.fromGLSL("void mainImage(out vec4 O, in vec2 F){O=vec4(1.0);}")
        var b = a
        a.name = "one"
        b.name = "two"
        XCTAssertEqual(a.contentHash, b.contentHash)
        XCTAssertEqual(a.contentHash.count, 64)
        b.passes[0].code += " "
        XCTAssertNotEqual(a.contentHash, b.contentHash)
    }

    func testDocumentRoundTripsThroughJSON() throws {
        let doc = try ShaderDocument.parse(try fixture("flower-evening.shadertoy", ext: "json"))
        let data = try JSONEncoder().encode(doc)
        XCTAssertEqual(try JSONDecoder().decode(ShaderDocument.self, from: data), doc)
    }

    // MARK: refusals

    /// `p.xz *= rot2(a)` — a compound assignment on a swizzle, with a matrix
    /// on the right — is rewritten to a plain assignment, which MSL accepts.
    func testCompoundAssignmentOnASwizzleCompiles() throws {
        let msl = try compile(try fixture("torus-flame"))
        XCTAssertTrue(msl.contains("p.xz = p.xz * (rot2(-iTime*0.3));"))
        XCTAssertTrue(msl.contains("p.zy = p.zy * (rot2(0.5));"))
        XCTAssertFalse(msl.contains(".xz *="))
        let scalar = try ShaderTranspiler.transpile("void mainImage(out vec4 O, in vec2 F) { vec3 p = vec3(F, 1.0); p.x *= 2.0; p.xy += 1.0; O = vec4(p, 1.0); }")
        XCTAssertTrue(scalar.contains("p.x *= 2.0;"))
        XCTAssertTrue(scalar.contains("p.xy = p.xy + (1.0);"))
    }

    /// A raymarched plate whose mouse parallax compares `iMouse.xy` to
    /// `vec2(0.0)` inside a ternary condition.
    func testLegoPlateCompiles() throws {
        let msl = try compile(try fixture("lego-plate"))
        XCTAssertTrue(msl.contains("float2 mouseN = all(mousePx == float2(0.0))"))
        XCTAssertTrue(msl.contains("bool isDot = (all(cx == DOT_CELL.x) && all(cy == DOT_CELL.y));"))
    }

    func testVectorEqualityIsOneBool() throws {
        let msl = try compile("""
        #define ZERO vec2(0.0)
        bool same(vec3 a, vec3 b) { return a == b; }
        void mainImage(out vec4 O, in vec2 F) {
            vec2 m = iMouse.xy;
            vec2 n = m == vec2(0.0) ? vec2(0.0) : (m - iResolution.xy * 0.5) / min(iResolution.x, iResolution.y);
            ivec2 cell = ivec2(floor(F / 8.0));
            bool dot = cell == ivec2(0, 1);
            int layer = int(F.x) % 2;
            bool front = F.y > 10.0;
            if ((layer == 1) != front && !same(vec3(n, 0.0), vec3(1.0))) layer = 0;
            float k = layer != 0 && m != ZERO ? 1.0 : 0.5;
            for (int i = 0; i != 3; i++) k += 0.1;
            mat2 mm = mat2(1.0);
            if (mm[0][1] == 0.0 && floor(n).x == -1.0 && same(vec3(n, 0.0), vec3(0.0)) == true) k *= 2.0;
            O = vec4(n, dot ? k : -k, 1.0);
        }
        """)
        XCTAssertTrue(msl.contains("if (all(mm[0][1] == 0.0) && all(floor(n).x == -1.0) && all(same(float3(n, 0.0), float3(0.0)) == true)) k *= 2.0;"))
        XCTAssertTrue(msl.contains("return all(a == b);"))
        XCTAssertTrue(msl.contains("float2 n = all(m == float2(0.0)) ? float2(0.0)"))
        XCTAssertTrue(msl.contains("bool dot = all(cell == int2(0, 1));"))
        XCTAssertTrue(msl.contains("if (any((all(layer == 1)) != front) && !same("))
        XCTAssertTrue(msl.contains("float k = any(layer != 0) && any(m != ZERO) ? 1.0 : 0.5;"))
        XCTAssertTrue(msl.contains("for (int i = 0; any(i != 3); i++)"))
        XCTAssertTrue(msl.contains("#define ZERO float2(0.0)"))
    }

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
