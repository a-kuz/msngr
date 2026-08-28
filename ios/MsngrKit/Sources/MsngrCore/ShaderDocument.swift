import Foundation
import CryptoKit

/// A shader as it travels in a message: the passes of a Shadertoy project
/// (`Image`, `Buffer A`–`D`, `Common`) with the wiring of their texture
/// channels. A single `mainImage` pasted as plain GLSL is a document of one
/// `image` pass.
public struct ShaderDocument: Codable, Equatable, Hashable, Sendable {
    public var name: String?
    /// In render order: buffers first, the image last; `common` anywhere, it
    /// is prepended to every other pass at compile time.
    public var passes: [ShaderPass]
    /// The shader drives the haptic engine: the image pass writes the
    /// intensity and sharpness it wants into the texel at fragment (0, 0).
    /// Set by `#pragma msngr haptics`.
    public var haptics: Bool?

    public init(name: String? = nil, passes: [ShaderPass], haptics: Bool? = nil) {
        self.name = name
        self.passes = passes
        self.haptics = haptics
    }

    /// The identity of a sticker: the same code with the same wiring is the
    /// same sticker wherever it was saved from.
    public var contentHash: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        var copy = self
        copy.name = nil
        let data = (try? enc.encode(copy)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether any pass mentions the uniform, so a sensor is started only for
    /// a shader that reads it.
    public func references(_ identifier: String) -> Bool {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: identifier) + "\\b"
        return passes.contains { $0.code.range(of: pattern, options: .regularExpression) != nil }
    }

    /// The live channel sources the document's passes read.
    public var liveSources: Set<String> {
        Set(passes.flatMap { $0.inputs.map(\.source) }.filter(ShaderInput.liveSources.contains))
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notAShader
        case noImagePass
        case tooLarge(bytes: Int)

        public var description: String {
            switch self {
            case .notAShader: return "neither GLSL with mainImage nor a Shadertoy export"
            case .noImagePass: return "the export has no Image pass"
            case .tooLarge(let n): return "the shader is \(n) bytes, the limit is \(ShaderTranspiler.maxSourceBytes)"
            }
        }
    }

    public var image: ShaderPass? { passes.first { $0.kind == .image } }
    public var buffers: [ShaderPass] { passes.filter { $0.kind == .buffer } }
    public var common: String { passes.first { $0.kind == .common }?.code ?? "" }
    public var sourceBytes: Int { passes.reduce(0) { $0 + $1.code.utf8.count } }

    /// The code the sender sees and the receiver can copy: the image pass for
    /// a one-pass shader, every pass under its name otherwise.
    public var displaySource: String {
        if passes.count == 1, let only = passes.first { return only.code }
        return passes.map { "// ==== \($0.title) ====\n\($0.code)" }.joined(separator: "\n\n")
    }

    // MARK: - Import

    /// Plain GLSL with `mainImage` or the JSON a Shadertoy export produces.
    public static func parse(_ text: String) throws -> ShaderDocument {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let doc: ShaderDocument
        if trimmed.hasPrefix("{") {
            // our own document (what the player copies for a multipass shader)
            // or a Shadertoy export
            if let own = try? JSONDecoder().decode(ShaderDocument.self, from: Data(trimmed.utf8)), own.image != nil {
                doc = own
            } else {
                doc = try fromShadertoyExport(Data(trimmed.utf8))
            }
        } else {
            guard trimmed.range(of: #"\bmainImage\s*\("#, options: .regularExpression) != nil else {
                throw Failure.notAShader
            }
            doc = fromGLSL(trimmed)
        }
        if doc.sourceBytes > ShaderTranspiler.maxSourceBytes { throw Failure.tooLarge(bytes: doc.sourceBytes) }
        return doc
    }

    /// One image pass. `#pragma msngr channelN <source>` lines rebind a channel
    /// (Shadertoy ignores unknown pragmas, so the same file runs there); the
    /// defaults are the textures Shadertoy authors reach for most, and the
    /// shader's own previous frame on channel 3. `#pragma msngr haptics`
    /// turns the haptic texel on.
    public static func fromGLSL(_ glsl: String) -> ShaderDocument {
        var inputs = ShaderInput.defaults(selfId: ShaderPass.imageId)
        let re = try! NSRegularExpression(pattern: #"(?m)^[ \t]*#[ \t]*pragma[ \t]+msngr[ \t]+channel([0-3])[ \t]+(\S+)[ \t]*$"#)
        for m in re.matches(in: glsl, range: NSRange(glsl.startIndex..., in: glsl)) {
            guard let c = Range(m.range(at: 1), in: glsl).flatMap({ Int(glsl[$0]) }),
                  let src = Range(m.range(at: 2), in: glsl).map({ String(glsl[$0]) }) else { continue }
            let source = src == "prevframe" ? ShaderInput.buffer(ShaderPass.imageId) : src
            // a live channel is a picture with an up and a down, and so is a
            // buffer the shader wrote itself; the noise textures wrap
            let clamps = src == "prevframe" || ShaderInput.liveSources.contains(src)
            inputs[c] = ShaderInput(channel: c, source: source, wrap: clamps ? "clamp" : "repeat")
        }
        let haptics = glsl.range(of: #"(?m)^[ \t]*#[ \t]*pragma[ \t]+msngr[ \t]+haptics[ \t]*$"#, options: .regularExpression) != nil
        return ShaderDocument(passes: [ShaderPass(id: ShaderPass.imageId, kind: .image, code: glsl, inputs: inputs)],
                              haptics: haptics ? true : nil)
    }

    /// The JSON of a Shadertoy export (`{"ver", "info", "renderpass": [...]}`).
    /// Sound and cubemap passes are left out; an input that is another
    /// pass's output becomes `buffer:<id>`, a media texture becomes noise, the
    /// keyboard, the microphone and the webcam become the device's own, and
    /// a video an empty channel.
    public static func fromShadertoyExport(_ data: Data) throws -> ShaderDocument {
        let export: Export
        do { export = try JSONDecoder().decode(Export.self, from: data) } catch { throw Failure.notAShader }
        // first the passes and the map from an output id to the pass that
        // writes it, then the inputs, which may point at a pass listed later
        var outputToPass: [String: String] = [:]
        var kept: [(pass: ShaderPass, raw: Export.RenderPass)] = []
        var bufferOrdinal = 0
        for rp in export.renderpass {
            let kind: ShaderPass.Kind
            let id: String
            switch rp.type {
            case "image": kind = .image; id = ShaderPass.imageId
            case "buffer":
                kind = .buffer
                let letter = rp.name.split(separator: " ").last.map(String.init) ?? ""
                id = ("A"..."D").contains(letter) && letter.count == 1
                    ? letter : String(UnicodeScalar(UInt8(65 + min(bufferOrdinal, 3))))
                bufferOrdinal += 1
            case "common": kind = .common; id = "common"
            default: continue
            }
            for out in rp.outputs ?? [] { outputToPass[out.id] = id }
            kept.append((ShaderPass(id: id, kind: kind, code: rp.code, inputs: []), rp))
        }
        guard kept.contains(where: { $0.pass.kind == .image }) else { throw Failure.noImagePass }
        var passes = kept.map { entry -> ShaderPass in
            var pass = entry.pass
            for input in entry.raw.inputs ?? [] where (0..<4).contains(input.channel) {
                let source: String
                switch input.type {
                case "buffer": source = outputToPass[input.id].map(ShaderInput.buffer) ?? ShaderInput.none
                case "texture": source = ShaderInput.noise
                case "keyboard": source = ShaderInput.keyboard
                case "mic", "music", "musicstream": source = ShaderInput.mic
                case "webcam": source = ShaderInput.camera
                default: source = ShaderInput.none
                }
                pass.inputs.append(ShaderInput(channel: input.channel, source: source,
                                               wrap: input.sampler?.wrap == "clamp" ? "clamp" : "repeat",
                                               filter: input.sampler?.filter ?? "linear",
                                               vflip: input.sampler?.vflip != "false"))
            }
            return pass
        }
        // common first, buffers in letter order, the image last
        passes.sort { a, b in a.order < b.order }
        return ShaderDocument(name: export.info?.name, passes: passes)
    }

    struct Export: Decodable {
        struct Info: Decodable { var name: String? }
        struct Sampler: Decodable { var filter: String?; var wrap: String?; var vflip: String? }
        struct Input: Decodable { var id: String; var type: String; var channel: Int; var sampler: Sampler? }
        struct Output: Decodable { var id: String; var channel: Int? }
        struct RenderPass: Decodable {
            var name: String
            var type: String
            var code: String
            var inputs: [Input]?
            var outputs: [Output]?
        }
        var info: Info?
        var renderpass: [RenderPass]
    }
}

public struct ShaderPass: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case image, buffer, common }
    public static let imageId = "image"

    /// `image`, `A`–`D`, or `common`.
    public var id: String
    public var kind: Kind
    public var code: String
    public var inputs: [ShaderInput]

    public init(id: String, kind: Kind, code: String, inputs: [ShaderInput]) {
        self.id = id
        self.kind = kind
        self.code = code
        self.inputs = inputs
    }

    public var title: String {
        switch kind {
        case .image: return "Image"
        case .common: return "Common"
        case .buffer: return "Buffer \(id)"
        }
    }

    /// The input on a channel, or an empty one.
    public func input(_ channel: Int) -> ShaderInput {
        inputs.first { $0.channel == channel } ?? ShaderInput(channel: channel, source: ShaderInput.none)
    }

    var order: Int {
        switch kind {
        case .common: return 0
        case .buffer: return 1 + Int(id.unicodeScalars.first?.value ?? 0)
        case .image: return 100
        }
    }
}

public struct ShaderInput: Codable, Equatable, Hashable, Sendable {
    public static let noise = "noise"          // 256×256 RGBA white noise
    public static let graynoise = "graynoise"  // 256×256 single-channel white noise
    public static let noise64 = "noise64"      // 64×64 RGBA white noise
    public static let none = "none"            // a 1×1 black texel
    /// The microphone as Shadertoy's sound texture: 512×2, row 0 the FFT
    /// magnitudes, row 1 the waveform, in the red channel.
    public static let mic = "mic"
    /// The back camera as a picture, and the front one.
    public static let camera = "camera"
    public static let cameraFront = "camera:front"
    /// Shadertoy's keyboard texture: 256×3, a column per key code, row 0 held,
    /// row 1 pressed this frame, row 2 toggled.
    public static let keyboard = "keyboard"
    public static let liveSources: Set<String> = [mic, camera, cameraFront, keyboard]
    public static func buffer(_ passId: String) -> String { "buffer:\(passId)" }

    public var channel: Int
    /// `noise` | `graynoise` | `noise64` | `none` | `mic` | `camera` |
    /// `camera:front` | `keyboard` | `buffer:<passId>`; a pass that reads its
    /// own buffer gets its previous frame.
    public var source: String
    public var wrap: String    // repeat | clamp
    public var filter: String  // linear | nearest | mipmap
    public var vflip: Bool

    public init(channel: Int, source: String, wrap: String = "repeat", filter: String = "linear", vflip: Bool = true) {
        self.channel = channel
        self.source = source
        self.wrap = wrap
        self.filter = filter
        self.vflip = vflip
    }

    /// The pass this input reads, if it reads one.
    public var bufferId: String? {
        source.hasPrefix("buffer:") ? String(source.dropFirst("buffer:".count)) : nil
    }

    public static func defaults(selfId: String) -> [ShaderInput] {
        [ShaderInput(channel: 0, source: noise),
         ShaderInput(channel: 1, source: graynoise),
         ShaderInput(channel: 2, source: noise64),
         ShaderInput(channel: 3, source: buffer(selfId), wrap: "clamp")]
    }
}
