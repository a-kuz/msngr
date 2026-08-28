import Foundation

/// Turns a shader written in the Shadertoy dialect of GLSL into a Metal
/// shading language source with one vertex and one fragment function.
///
/// The user's code is placed inside `struct MsngrShaderToy`, whose data
/// members are the Shadertoy uniforms, so `iTime` and `iResolution` are visible
/// from every user function and the functions may call each other in any
/// order. Program-scope `const` declarations of builtin types are hoisted
/// above the struct as `constant` globals, so a lookup table costs no
/// per-thread copy. A shim of free functions supplies what GLSL has and MSL
/// does not (`mod`, `inverse`, `atan(y, x)`, the scalar-broadcast overloads).
public enum ShaderTranspiler {
    /// A message is one value in the conversation's Durable Object storage,
    /// whose ceiling is 128 KiB; the source travels base64-encoded inside the
    /// envelope, so 64 KB of GLSL is what fits with room for the rest.
    public static let maxSourceBytes = 64 * 1024
    public static let vertexFunction = "msngr_shader_vert"
    public static let fragmentFunction = "msngr_shader_frag"
    public static let language = "glsl-st"

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case tooLarge(bytes: Int)
        case noMainImage
        case unsupported(String)

        public var description: String {
            switch self {
            case .tooLarge(let n): return "source is \(n) bytes, the limit is \(maxSourceBytes)"
            case .noMainImage: return "mainImage(out vec4, in vec2) not found"
            case .unsupported(let what): return "\(what) is not supported"
            }
        }
    }

    /// The uniform block the fragment function reads from `buffer(0)`; the
    /// app fills a matching struct of `SIMD4<Float>`s:
    /// `(iTime, iTimeDelta, iFrame, 0)`, `(iResolution.xyz, 0)`, `iMouse`, `iDate`,
    /// then `iChannelResolution[0..3]` as four `(w, h, 1, 0)`. The four texture
    /// channels arrive as `texture(0..3)` with their samplers as `sampler(0..3)`.
    public static let uniformStride = 128

    /// One pass of a document into MSL. `common` is the shared code of a
    /// multipass shader, placed ahead of the pass's own.
    public static func transpile(_ glsl: String, common: String = "") throws -> String {
        let bytes = glsl.utf8.count + common.utf8.count
        if bytes > maxSourceBytes { throw Failure.tooLarge(bytes: bytes) }

        var s = stripComments(common.isEmpty ? glsl : common + "\n" + glsl)
        s = dropDirectives(s)
        if matches(#"\bmainSound\s*\(|\bmainVR\s*\("#, in: s) {
            throw Failure.unsupported("mainSound / mainVR")
        }
        if matches(#"\bsamplerCube\b|\bsampler3D\b|\btextureCube\s*\("#, in: s) {
            throw Failure.unsupported("cube and volume textures")
        }
        s = renameReservedIdentifiers(s)
        s = renameTypes(s)
        s = rewriteParameterQualifiers(s)
        s = rewriteArrayConstructors(s)
        s = rewriteStructConstructors(s)
        s = replace(#"\b([A-Za-z_]\w*)\.length\(\)"#, in: s, with: "(int)(sizeof($1)/sizeof($1[0]))")
        s = replace(#"\bdiscard\s*;"#, in: s, with: "discard_fragment();")
        if !matches(#"\bmainImage\s*\(\s*thread\s+float4\s*&\s*\w+\s*,\s*float2\s+\w+\s*\)"#, in: s) {
            throw Failure.noMainImage
        }

        let items = splitTopLevel(s)
        var hoisted: [String] = []
        var body: [String] = []
        // names of program-scope constants that stayed inside the struct: a
        // constant built from one of them cannot be hoisted either
        var memberConstants: Set<String> = []
        for item in items {
            let t = item.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || isPrototype(t) { continue }
            if isHoistableConstant(t, memberConstants: memberConstants) {
                hoisted.append("constant " + String(t.dropFirst("const".count)).trimmingCharacters(in: .whitespaces))
            } else {
                if t.hasPrefix("const"), let name = declaredName(t) { memberConstants.insert(name) }
                body.append(t)
            }
        }

        var out = prelude
        out += hoisted.joined(separator: "\n") + "\n\n"
        out += "struct MsngrShaderToy {\n"
        out += "  float iTime; float iTimeDelta; int iFrame; float3 iResolution; float4 iMouse; float4 iDate;\n"
        out += "  float iSampleRate = 44100.0;\n"
        out += "  MsngrChannel iChannel0, iChannel1, iChannel2, iChannel3;\n"
        out += "  float3 iChannelResolution[4];\n"
        out += "  float iChannelTime[4] = {0.0, 0.0, 0.0, 0.0};\n\n"
        out += body.joined(separator: "\n") + "\n"
        out += "};\n\n"
        out += epilogue
        return out
    }

    // MARK: - Passes

    static func stripComments(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        let chars = Array(s.unicodeScalars)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "/" {
                while i < chars.count && chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count && !(chars[i] == "*" && chars[i + 1] == "/") {
                    if chars[i] == "\n" { out.unicodeScalars.append("\n") }
                    i += 1
                }
                i += 2
                continue
            }
            out.unicodeScalars.append(c)
            i += 1
        }
        return out
    }

    /// `#version` and `precision` are GLSL-only; `#define`, `#if` and the
    /// rest are the same preprocessor and stay.
    static func dropDirectives(_ s: String) -> String {
        var out = replace(#"(?m)^[ \t]*#[ \t]*(version|extension|pragma[ \t]+msngr)\b[^\n]*$"#, in: s, with: "")
        out = replace(#"(?m)^[ \t]*precision\s+(lowp|mediump|highp)\s+\w+\s*;[ \t]*$"#, in: out, with: "")
        out = replace(#"\b(lowp|mediump|highp)\s+"#, in: out, with: "")
        return out
    }

    /// Legal GLSL identifiers that are keywords or reserved names in MSL.
    static let reserved: Set<String> = [
        "half", "kernel", "vertex", "fragment", "constant", "device", "thread", "threadgroup",
        "sampler", "class", "template", "this", "new", "delete", "char", "short", "long",
        "unsigned", "signed", "auto", "static", "union", "typedef", "virtual", "throw", "try",
        "catch", "goto", "sizeof", "mutable", "explicit", "export", "extern", "inline", "volatile",
        "register", "namespace", "using", "operator", "private", "protected", "public", "friend",
        "typename", "typeid", "constexpr", "decltype", "nullptr", "static_assert", "thread_local",
        "alignas", "alignof", "noexcept", "and", "or", "xor", "compl", "bitand", "bitor", "and_eq",
        "or_eq", "xor_eq", "not_eq", "asm", "wchar_t", "char16_t", "char32_t", "ushort", "uchar",
        "size_t", "ptrdiff_t", "array", "metal", "main", "select", "saturate", "rint", "rsqrt",
        "fmod", "fmin", "fmax", "atan2", "dfdx", "dfdy", "as_type", "half2", "half3", "half4",
        "float2", "float3", "float4", "int2", "int3", "int4", "uint2", "uint3", "uint4",
        "bool2", "bool3", "bool4", "float2x2", "float3x3", "float4x4",
    ]

    static func renameReservedIdentifiers(_ s: String) -> String {
        let alternation = reserved.sorted().joined(separator: "|")
        return replace("\\b(\(alternation))\\b", in: s, with: "$1_")
    }

    static let typeMap: [(String, String)] = [
        ("vec2", "float2"), ("vec3", "float3"), ("vec4", "float4"),
        ("ivec2", "int2"), ("ivec3", "int3"), ("ivec4", "int4"),
        ("uvec2", "uint2"), ("uvec3", "uint3"), ("uvec4", "uint4"),
        ("bvec2", "bool2"), ("bvec3", "bool3"), ("bvec4", "bool4"),
        ("mat2", "float2x2"), ("mat3", "float3x3"), ("mat4", "float4x4"),
        ("mat2x2", "float2x2"), ("mat2x3", "float2x3"), ("mat2x4", "float2x4"),
        ("mat3x2", "float3x2"), ("mat3x3", "float3x3"), ("mat3x4", "float3x4"),
        ("mat4x2", "float4x2"), ("mat4x3", "float4x3"), ("mat4x4", "float4x4"),
        ("dFdx", "dfdx"), ("dFdy", "dfdy"),
    ]

    static func renameTypes(_ s: String) -> String {
        var out = s
        for (from, to) in typeMap {
            out = replace("\\b\(from)\\b", in: out, with: to)
        }
        return out
    }

    /// `out T x` / `inout T x` → `thread T& x`; `in T x` → `T x`. Only inside
    /// a parameter list, where these words are qualifiers in GLSL.
    static func rewriteParameterQualifiers(_ s: String) -> String {
        var out = replace(#"\b(?:out|inout)\s+(const\s+)?([A-Za-z_]\w*)\s+([A-Za-z_]\w*)"#, in: s, with: "thread $2& $3")
        out = replace(#"\bin\s+(const\s+)?([A-Za-z_]\w*)\s+([A-Za-z_]\w*)"#, in: out, with: "$1$2 $3")
        return out
    }

    /// `T[](a, b)` and `T[N](a, b)` → `{a, b}`.
    static func rewriteArrayConstructors(_ s: String) -> String {
        bracify(s, pattern: #"\b([A-Za-z_]\w*)\s*\[\s*\d*\s*\]\s*\("#, keepName: false)
    }

    /// GLSL builds a user struct with `Ray(o, d)`; C++ has no such
    /// constructor, aggregate initialization `Ray{o, d}` is the same thing.
    static func rewriteStructConstructors(_ s: String) -> String {
        let names = try! NSRegularExpression(pattern: #"\bstruct\s+([A-Za-z_]\w*)\s*\{"#)
            .matches(in: s, range: NSRange(s.startIndex..., in: s))
            .compactMap { Range($0.range(at: 1), in: s).map { String(s[$0]) } }
        if names.isEmpty { return s }
        let alternation = names.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return bracify(s, pattern: "(?<!struct\\s)\\b(\(alternation))\\s*\\(", keepName: true)
    }

    /// Every match of `pattern` (which must end at an opening paren) has its
    /// paren pair turned into braces; the matched prefix is kept or dropped.
    static func bracify(_ s: String, pattern: String, keepName: Bool) -> String {
        let re = try! NSRegularExpression(pattern: pattern)
        var chars = Array(s)
        var searchFrom = 0
        while true {
            let str = String(chars)
            let from = str.index(str.startIndex, offsetBy: searchFrom)
            guard let m = re.firstMatch(in: str, range: NSRange(from..., in: str)),
                  let r = Range(m.range, in: str) else { break }
            let start = str.distance(from: str.startIndex, to: r.lowerBound)
            let open = str.distance(from: str.startIndex, to: r.upperBound) - 1
            var depth = 0
            var close = open
            while close < chars.count {
                if chars[close] == "(" { depth += 1 }
                if chars[close] == ")" { depth -= 1; if depth == 0 { break } }
                close += 1
            }
            if close >= chars.count { break }
            chars[close] = "}"
            if keepName {
                chars[open] = "{"
                searchFrom = open + 1
            } else {
                chars.replaceSubrange(start...open, with: Array("{"))
                searchFrom = start + 1
            }
        }
        return String(chars)
    }

    /// A function prototype has no place inside the struct: the definition is
    /// a member already, and members see each other in any order.
    static func isPrototype(_ item: String) -> Bool {
        matches(#"^[A-Za-z_]\w*\s+[A-Za-z_]\w*\s*\([^()={}]*\)\s*;$"#, in: item)
    }

    /// Cuts the program into its top-level pieces: a function ends at the `}`
    /// closing its body, anything else at a `;` at depth zero, a preprocessor
    /// line at its newline.
    static func splitTopLevel(_ s: String) -> [String] {
        var items: [String] = []
        var cur = ""
        var depth = 0
        var paren = 0
        var lastSignificant: Character = " "
        var functionBody = false
        var atLineStart = true
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if depth == 0 && atLineStart && c == "#" && cur.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var line = ""
                while i < chars.count && chars[i] != "\n" { line.append(chars[i]); i += 1 }
                items.append(line)
                cur = ""
                continue
            }
            cur.append(c)
            if c == "\n" { atLineStart = true } else if !c.isWhitespace { atLineStart = false }
            switch c {
            case "(": paren += 1
            case ")": paren -= 1
            case "{":
                if depth == 0 { functionBody = (lastSignificant == ")") }
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 && functionBody {
                    items.append(cur); cur = ""; functionBody = false
                }
            case ";":
                if depth == 0 && paren == 0 { items.append(cur); cur = "" }
            default: break
            }
            if !c.isWhitespace { lastSignificant = c }
            i += 1
        }
        if !cur.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { items.append(cur) }
        return items
    }

    static let builtinTypes: Set<String> = [
        "float", "int", "uint", "bool",
        "float2", "float3", "float4", "int2", "int3", "int4", "uint2", "uint3", "uint4",
        "bool2", "bool3", "bool4", "float2x2", "float2x3", "float2x4", "float3x2", "float3x3",
        "float3x4", "float4x2", "float4x3", "float4x4",
    ]

    /// A program-scope `const` of a builtin type whose initializer is a
    /// constant expression: literals, arithmetic, vector and matrix
    /// constructors, other hoisted constants. Metal rejects a `constant`
    /// global built by a function call (`normalize(...)` is a global
    /// constructor), so such a constant stays a struct member and is computed
    /// per fragment, exactly as GLSL would.
    static func isHoistableConstant(_ item: String, memberConstants: Set<String>) -> Bool {
        guard item.hasPrefix("const"), item.hasSuffix(";") else { return false }
        let words = item.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
        guard words.count >= 2, words[0] == "const", builtinTypes.contains(String(words[1])) else { return false }
        guard let eq = item.firstIndex(of: "=") else { return true }
        let initializer = String(item[item.index(after: eq)...])
        let calls = try! NSRegularExpression(pattern: #"\b([A-Za-z_]\w*)\s*\("#)
            .matches(in: initializer, range: NSRange(initializer.startIndex..., in: initializer))
            .compactMap { Range($0.range(at: 1), in: initializer).map { String(initializer[$0]) } }
        if calls.contains(where: { !builtinTypes.contains($0) }) { return false }
        let names = try! NSRegularExpression(pattern: #"\b([A-Za-z_]\w*)\b"#)
            .matches(in: initializer, range: NSRange(initializer.startIndex..., in: initializer))
            .compactMap { Range($0.range(at: 1), in: initializer).map { String(initializer[$0]) } }
        return !names.contains(where: memberConstants.contains)
    }

    /// The name a `const T name...` declaration introduces.
    static func declaredName(_ item: String) -> String? {
        let words = item.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
        return words.count >= 3 ? String(words[2]) : nil
    }

    // MARK: - Regex helpers

    static func matches(_ pattern: String, in s: String) -> Bool {
        let re = try! NSRegularExpression(pattern: pattern)
        return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func replace(_ pattern: String, in s: String, with template: String) -> String {
        let re = try! NSRegularExpression(pattern: pattern)
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    // MARK: - Emitted MSL around the user's code

    static let prelude = """
    #include <metal_stdlib>
    using namespace metal;

    // GLSL library functions MSL spells differently or lacks.
    inline float mod(float x, float y) { return x - y * floor(x / y); }
    inline float2 mod(float2 x, float2 y) { return x - y * floor(x / y); }
    inline float3 mod(float3 x, float3 y) { return x - y * floor(x / y); }
    inline float4 mod(float4 x, float4 y) { return x - y * floor(x / y); }
    inline float2 mod(float2 x, float y) { return x - y * floor(x / y); }
    inline float3 mod(float3 x, float y) { return x - y * floor(x / y); }
    inline float4 mod(float4 x, float y) { return x - y * floor(x / y); }
    inline float atan(float y, float x) { return atan2(y, x); }
    inline float2 atan(float2 y, float2 x) { return atan2(y, x); }
    inline float3 atan(float3 y, float3 x) { return atan2(y, x); }
    inline float4 atan(float4 y, float4 x) { return atan2(y, x); }
    inline float radians(float d) { return d * 0.017453292519943295; }
    inline float2 radians(float2 d) { return d * 0.017453292519943295; }
    inline float3 radians(float3 d) { return d * 0.017453292519943295; }
    inline float4 radians(float4 d) { return d * 0.017453292519943295; }
    inline float degrees(float r) { return r * 57.29577951308232; }
    inline float2 degrees(float2 r) { return r * 57.29577951308232; }
    inline float3 degrees(float3 r) { return r * 57.29577951308232; }
    inline float4 degrees(float4 r) { return r * 57.29577951308232; }
    inline float inversesqrt(float x) { return rsqrt(x); }
    inline float2 inversesqrt(float2 x) { return rsqrt(x); }
    inline float3 inversesqrt(float3 x) { return rsqrt(x); }
    inline float4 inversesqrt(float4 x) { return rsqrt(x); }
    inline float roundEven(float x) { return rint(x); }
    inline float2 roundEven(float2 x) { return rint(x); }
    inline float3 roundEven(float3 x) { return rint(x); }
    inline float4 roundEven(float4 x) { return rint(x); }
    inline float2 clamp(float2 x, float a, float b) { return clamp(x, float2(a), float2(b)); }
    inline float3 clamp(float3 x, float a, float b) { return clamp(x, float3(a), float3(b)); }
    inline float4 clamp(float4 x, float a, float b) { return clamp(x, float4(a), float4(b)); }
    inline int2 clamp(int2 x, int a, int b) { return clamp(x, int2(a), int2(b)); }
    inline int3 clamp(int3 x, int a, int b) { return clamp(x, int3(a), int3(b)); }
    inline int4 clamp(int4 x, int a, int b) { return clamp(x, int4(a), int4(b)); }
    inline float2 min(float2 x, float y) { return min(x, float2(y)); }
    inline float3 min(float3 x, float y) { return min(x, float3(y)); }
    inline float4 min(float4 x, float y) { return min(x, float4(y)); }
    inline float2 max(float2 x, float y) { return max(x, float2(y)); }
    inline float3 max(float3 x, float y) { return max(x, float3(y)); }
    inline float4 max(float4 x, float y) { return max(x, float4(y)); }
    inline int2 min(int2 x, int y) { return min(x, int2(y)); }
    inline int3 min(int3 x, int y) { return min(x, int3(y)); }
    inline int4 min(int4 x, int y) { return min(x, int4(y)); }
    inline int2 max(int2 x, int y) { return max(x, int2(y)); }
    inline int3 max(int3 x, int y) { return max(x, int3(y)); }
    inline int4 max(int4 x, int y) { return max(x, int4(y)); }
    inline float2 smoothstep(float a, float b, float2 x) { return smoothstep(float2(a), float2(b), x); }
    inline float3 smoothstep(float a, float b, float3 x) { return smoothstep(float3(a), float3(b), x); }
    inline float4 smoothstep(float a, float b, float4 x) { return smoothstep(float4(a), float4(b), x); }
    inline float2 step(float a, float2 x) { return step(float2(a), x); }
    inline float3 step(float a, float3 x) { return step(float3(a), x); }
    inline float4 step(float a, float4 x) { return step(float4(a), x); }
    inline float2 pow(float2 x, float y) { return pow(x, float2(y)); }
    inline float3 pow(float3 x, float y) { return pow(x, float3(y)); }
    inline float4 pow(float4 x, float y) { return pow(x, float4(y)); }
    inline float2x2 inverse(float2x2 m) {
        float d = m[0][0] * m[1][1] - m[1][0] * m[0][1];
        return float2x2(float2(m[1][1], -m[0][1]), float2(-m[1][0], m[0][0])) * (1.0 / d);
    }
    inline float3x3 inverse(float3x3 m) {
        float3 a = m[0], b = m[1], c = m[2];
        float3 r0 = cross(b, c), r1 = cross(c, a), r2 = cross(a, b);
        float d = dot(a, r0);
        return transpose(float3x3(r0, r1, r2)) * (1.0 / d);
    }
    inline float4x4 inverse(float4x4 m) {
        float4 c0 = m[0], c1 = m[1], c2 = m[2], c3 = m[3];
        float s0 = c0.x * c1.y - c1.x * c0.y, s1 = c0.x * c1.z - c1.x * c0.z, s2 = c0.x * c1.w - c1.x * c0.w;
        float s3 = c0.y * c1.z - c1.y * c0.z, s4 = c0.y * c1.w - c1.y * c0.w, s5 = c0.z * c1.w - c1.z * c0.w;
        float t0 = c2.z * c3.w - c3.z * c2.w, t1 = c2.y * c3.w - c3.y * c2.w, t2 = c2.y * c3.z - c3.y * c2.z;
        float t3 = c2.x * c3.w - c3.x * c2.w, t4 = c2.x * c3.z - c3.x * c2.z, t5 = c2.x * c3.y - c3.x * c2.y;
        float d = s0 * t0 - s1 * t1 + s2 * t2 + s3 * t3 - s4 * t4 + s5 * t5;
        float id = 1.0 / d;
        float4x4 r;
        r[0][0] = ( c1.y * t0 - c1.z * t1 + c1.w * t2) * id;
        r[0][1] = (-c0.y * t0 + c0.z * t1 - c0.w * t2) * id;
        r[0][2] = ( c3.y * s5 - c3.z * s4 + c3.w * s3) * id;
        r[0][3] = (-c2.y * s5 + c2.z * s4 - c2.w * s3) * id;
        r[1][0] = (-c1.x * t0 + c1.z * t3 - c1.w * t4) * id;
        r[1][1] = ( c0.x * t0 - c0.z * t3 + c0.w * t4) * id;
        r[1][2] = (-c3.x * s5 + c3.z * s2 - c3.w * s1) * id;
        r[1][3] = ( c2.x * s5 - c2.z * s2 + c2.w * s1) * id;
        r[2][0] = ( c1.x * t1 - c1.y * t3 + c1.w * t5) * id;
        r[2][1] = (-c0.x * t1 + c0.y * t3 - c0.w * t5) * id;
        r[2][2] = ( c3.x * s4 - c3.y * s2 + c3.w * s0) * id;
        r[2][3] = (-c2.x * s4 + c2.y * s2 - c2.w * s0) * id;
        r[3][0] = (-c1.x * t2 + c1.y * t4 - c1.z * t5) * id;
        r[3][1] = ( c0.x * t2 - c0.y * t4 + c0.z * t5) * id;
        r[3][2] = (-c3.x * s3 + c3.y * s1 - c3.z * s0) * id;
        r[3][3] = ( c2.x * s3 - c2.y * s1 + c2.z * s0) * id;
        return r;
    }
    inline float2x2 matrixCompMult(float2x2 a, float2x2 b) { return float2x2(a[0] * b[0], a[1] * b[1]); }
    inline float3x3 matrixCompMult(float3x3 a, float3x3 b) { return float3x3(a[0] * b[0], a[1] * b[1], a[2] * b[2]); }
    inline float4x4 matrixCompMult(float4x4 a, float4x4 b) { return float4x4(a[0] * b[0], a[1] * b[1], a[2] * b[2], a[3] * b[3]); }
    template <typename T> inline auto lessThan(T a, T b) { return a < b; }
    template <typename T> inline auto lessThanEqual(T a, T b) { return a <= b; }
    template <typename T> inline auto greaterThan(T a, T b) { return a > b; }
    template <typename T> inline auto greaterThanEqual(T a, T b) { return a >= b; }
    template <typename T> inline auto equal(T a, T b) { return a == b; }
    template <typename T> inline auto notEqual(T a, T b) { return a != b; }
    inline int floatBitsToInt(float x) { return as_type<int>(x); }
    inline int2 floatBitsToInt(float2 x) { return as_type<int2>(x); }
    inline int3 floatBitsToInt(float3 x) { return as_type<int3>(x); }
    inline int4 floatBitsToInt(float4 x) { return as_type<int4>(x); }
    inline uint floatBitsToUint(float x) { return as_type<uint>(x); }
    inline uint2 floatBitsToUint(float2 x) { return as_type<uint2>(x); }
    inline uint3 floatBitsToUint(float3 x) { return as_type<uint3>(x); }
    inline uint4 floatBitsToUint(float4 x) { return as_type<uint4>(x); }
    inline float intBitsToFloat(int x) { return as_type<float>(x); }
    inline float2 intBitsToFloat(int2 x) { return as_type<float2>(x); }
    inline float3 intBitsToFloat(int3 x) { return as_type<float3>(x); }
    inline float4 intBitsToFloat(int4 x) { return as_type<float4>(x); }
    inline float uintBitsToFloat(uint x) { return as_type<float>(x); }
    inline float2 uintBitsToFloat(uint2 x) { return as_type<float2>(x); }
    inline float3 uintBitsToFloat(uint3 x) { return as_type<float3>(x); }
    inline float4 uintBitsToFloat(uint4 x) { return as_type<float4>(x); }

    // Texture channels: a texture with the sampler the document asked for.
    // GLSL's sampling functions become free functions over the channel. The
    // vertical flip keeps the y-up fragment coordinates consistent between a
    // pass writing a buffer and a pass reading it: texel (x, y) read here is
    // the texel fragment (x, y) wrote.
    struct MsngrChannel { texture2d<float> tex; sampler smp; };
    inline float2 msngrFlip(float2 uv) { return float2(uv.x, 1.0 - uv.y); }
    inline uint2 msngrFlip(MsngrChannel c, int2 p) { return uint2(uint(p.x), c.tex.get_height() - 1u - uint(p.y)); }
    inline float4 texture(MsngrChannel c, float2 uv) { return c.tex.sample(c.smp, msngrFlip(uv)); }
    inline float4 texture(MsngrChannel c, float2 uv, float b) { return c.tex.sample(c.smp, msngrFlip(uv), bias(b)); }
    inline float4 textureLod(MsngrChannel c, float2 uv, float lod) { return c.tex.sample(c.smp, msngrFlip(uv), level(lod)); }
    inline float4 textureGrad(MsngrChannel c, float2 uv, float2 dx, float2 dy) { return c.tex.sample(c.smp, msngrFlip(uv), gradient2d(dx, dy)); }
    inline float4 texelFetch(MsngrChannel c, int2 p, int lod) { return c.tex.read(msngrFlip(c, p), uint(lod)); }
    inline int2 textureSize(MsngrChannel c, int lod) { return int2(c.tex.get_width(uint(lod)), c.tex.get_height(uint(lod))); }

    struct MsngrShaderUniforms {
        float4 timeFrame;   // iTime, iTimeDelta, iFrame, 0
        float4 resolution;  // iResolution.xyz, 0
        float4 mouse;
        float4 date;
        float4 channelResolution[4];
    };


    """

    static let epilogue = """
    struct MsngrVOut { float4 position [[position]]; };

    vertex MsngrVOut \(vertexFunction)(uint vid [[vertex_id]]) {
        float2 p = float2(vid == 2 ? 3.0 : -1.0, vid == 1 ? 3.0 : -1.0);
        MsngrVOut o;
        o.position = float4(p, 0.0, 1.0);
        return o;
    }

    fragment float4 \(fragmentFunction)(MsngrVOut in [[stage_in]],
                                        constant MsngrShaderUniforms& u [[buffer(0)]],
                                        texture2d<float> t0 [[texture(0)]], sampler s0 [[sampler(0)]],
                                        texture2d<float> t1 [[texture(1)]], sampler s1 [[sampler(1)]],
                                        texture2d<float> t2 [[texture(2)]], sampler s2 [[sampler(2)]],
                                        texture2d<float> t3 [[texture(3)]], sampler s3 [[sampler(3)]]) {
        MsngrShaderToy s;
        s.iTime = u.timeFrame.x;
        s.iTimeDelta = u.timeFrame.y;
        s.iFrame = int(u.timeFrame.z);
        s.iResolution = u.resolution.xyz;
        s.iMouse = u.mouse;
        s.iDate = u.date;
        s.iChannel0 = MsngrChannel{t0, s0}; s.iChannel1 = MsngrChannel{t1, s1};
        s.iChannel2 = MsngrChannel{t2, s2}; s.iChannel3 = MsngrChannel{t3, s3};
        for (int i = 0; i < 4; i++) s.iChannelResolution[i] = u.channelResolution[i].xyz;
        float4 O = float4(0.0, 0.0, 0.0, 1.0);
        float2 F = float2(in.position.x, u.resolution.y - in.position.y);
        s.mainImage(O, F);
        return O;
    }

    """
}
