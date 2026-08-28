import Metal
import MetalKit
import UIKit
import MsngrCore

/// The GPU shared by every shader on screen: one device, one command queue,
/// the noise textures Shadertoy channels default to, and the samplers.
final class ShaderGPU {
    static let shared = ShaderGPU()

    let device: MTLDevice?
    let queue: MTLCommandQueue?
    /// Buffers keep HDR: a path tracer accumulates in linear light and a
    /// 16-bit float texture would clip the sun it is adding up.
    let bufferFormat: MTLPixelFormat
    private var samplers: [String: MTLSamplerState] = [:]
    private var textures: [String: MTLTexture] = [:]
    private let lock = NSLock()

    private init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        bufferFormat = (device?.supports32BitFloatFiltering ?? false) ? .rgba32Float : .rgba16Float
    }

    /// The sampler an input asks for; Shadertoy's defaults are repeat and linear.
    func sampler(wrap: String, filter: String) -> MTLSamplerState? {
        let key = "\(wrap)|\(filter)"
        lock.lock(); defer { lock.unlock() }
        if let hit = samplers[key] { return hit }
        let d = MTLSamplerDescriptor()
        let address: MTLSamplerAddressMode = wrap == "clamp" ? .clampToEdge : .repeat
        d.sAddressMode = address
        d.tAddressMode = address
        d.minFilter = filter == "nearest" ? .nearest : .linear
        d.magFilter = filter == "nearest" ? .nearest : .linear
        d.mipFilter = filter == "mipmap" ? .linear : .notMipmapped
        guard let s = device?.makeSamplerState(descriptor: d) else { return nil }
        samplers[key] = s
        return s
    }

    /// A static channel source: the noise textures and the empty texel.
    func texture(for source: String) -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        if let hit = textures[source] { return hit }
        let made: MTLTexture?
        switch source {
        case ShaderInput.noise: made = makeNoise(size: 256, gray: false, seed: 1)
        case ShaderInput.graynoise: made = makeNoise(size: 256, gray: true, seed: 2)
        case ShaderInput.noise64: made = makeNoise(size: 64, gray: false, seed: 3)
        default: made = makeBlack()
        }
        if let made { textures[source] = made }
        return made
    }

    private func makeNoise(size: Int, gray: Bool, seed: UInt64) -> MTLTexture? {
        var state = seed &* 0x9E3779B97F4A7C15
        func next() -> UInt8 {
            // xorshift64*: cheap, and the same picture on every device, so a
            // shader sampling noise looks the same to the sender and the peer
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            return UInt8(truncatingIfNeeded: (state &* 0x2545F4914F6CDD1D) >> 56)
        }
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            if gray {
                let v = next()
                pixels[i] = v; pixels[i + 1] = v; pixels[i + 2] = v; pixels[i + 3] = 255
            } else {
                pixels[i] = next(); pixels[i + 1] = next(); pixels[i + 2] = next(); pixels[i + 3] = next()
            }
        }
        return upload(pixels, size: size)
    }

    private func makeBlack() -> MTLTexture? { upload([0, 0, 0, 255], size: 1) }

    private func upload(_ pixels: [UInt8], size: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device?.makeTexture(descriptor: d) else { return nil }
        pixels.withUnsafeBytes { raw in
            t.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                      withBytes: raw.baseAddress!, bytesPerRow: size * 4)
        }
        return t
    }
}

/// A document compiled for the GPU: one pipeline per pass. Compiles once per
/// distinct document and is shared by every view that shows it.
final class ShaderProgram {
    enum State {
        case compiling
        case ready([CompiledPass])
        case failed(String)
    }

    struct CompiledPass {
        let pass: ShaderPass
        let pipeline: MTLRenderPipelineState
    }

    let document: ShaderDocument
    private(set) var state: State = .compiling
    private var observers: [UUID: (State) -> Void] = [:]
    private let lock = NSLock()

    /// Longer than any honest compile; a source built to keep the compiler
    /// busy is shown as failed instead of holding the bubble forever.
    static let compileTimeout: TimeInterval = 15

    private static var cache: [ShaderDocument: ShaderProgram] = [:]
    private static let cacheLock = NSLock()
    private static let compileQueue = DispatchQueue(label: "msngr.shader.compile", qos: .userInitiated)

    static func program(for document: ShaderDocument) -> ShaderProgram {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let hit = cache[document] { return hit }
        let p = ShaderProgram(document: document)
        cache[document] = p
        p.compile()
        return p
    }

    private init(document: ShaderDocument) {
        self.document = document
    }

    /// Calls back with the current state at once and with every change after,
    /// on the main queue. The token removes the observer.
    @discardableResult
    func observe(_ handler: @escaping (State) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        observers[id] = handler
        let now = state
        lock.unlock()
        DispatchQueue.main.async { handler(now) }
        return id
    }

    func unobserve(_ id: UUID) {
        lock.lock(); observers[id] = nil; lock.unlock()
    }

    private func set(_ new: State) {
        lock.lock()
        state = new
        let handlers = Array(observers.values)
        lock.unlock()
        DispatchQueue.main.async { handlers.forEach { $0(new) } }
    }

    /// A command buffer that ended in an error (the GPU gave up on the frame)
    /// takes the program down for the rest of the process.
    func fail(_ reason: String) {
        lock.lock()
        let already = { if case .failed = self.state { return true } else { return false } }()
        lock.unlock()
        if already { return }
        MsngrLog.shader.error("shader failed: \(reason, privacy: .public)")
        set(.failed(reason))
    }

    private func compile() {
        guard let device = ShaderGPU.shared.device else {
            set(.failed("no GPU"))
            return
        }
        var finished = false
        let finishedLock = NSLock()
        let doc = document
        Self.compileQueue.async { [weak self] in
            let result: Result<[CompiledPass], Error> = Result {
                try doc.passes.filter { $0.kind != .common }.map { pass in
                    let msl = try ShaderTranspiler.transpile(pass.code, common: doc.common)
                    let lib = try device.makeLibrary(source: msl, options: nil)
                    let desc = MTLRenderPipelineDescriptor()
                    desc.vertexFunction = lib.makeFunction(name: ShaderTranspiler.vertexFunction)
                    desc.fragmentFunction = lib.makeFunction(name: ShaderTranspiler.fragmentFunction)
                    desc.colorAttachments[0].pixelFormat = pass.kind == .image
                        ? ShaderRenderer.imageFormat : ShaderGPU.shared.bufferFormat
                    return CompiledPass(pass: pass, pipeline: try device.makeRenderPipelineState(descriptor: desc))
                }
            }
            finishedLock.lock()
            let late = finished
            finished = true
            finishedLock.unlock()
            guard !late, let self else { return }
            switch result {
            case .success(let passes): self.set(.ready(passes))
            case .failure(let error): self.set(.failed(Self.firstLine(of: error)))
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.compileTimeout) { [weak self] in
            finishedLock.lock()
            let done = finished
            finished = true
            finishedLock.unlock()
            if !done { self?.set(.failed("compile timed out")) }
        }
    }

    /// The compiler's message without the MSL line numbers, which point into
    /// the transpiled source and not into what the author wrote.
    static func firstLine(of error: Error) -> String {
        let text = (error as NSError).localizedDescription
        let lines = text.split(separator: "\n").map(String.init)
        let errorLine = lines.first { $0.contains("error:") } ?? lines.first ?? text
        if let r = errorLine.range(of: "error: ") { return String(errorLine[r.upperBound...]) }
        return errorLine
    }
}

/// Draws one document into an `MTKView`: runs the buffer passes into their
/// textures, the image pass into the drawable, keeps time, the frame counter
/// and the mouse the way Shadertoy defines them.
final class ShaderRenderer: NSObject, MTKViewDelegate {
    static let imageFormat: MTLPixelFormat = .bgra8Unorm

    let program: ShaderProgram
    private var compiled: [ShaderProgram.CompiledPass] = []
    private var observer: UUID?
    private let uniforms: MTLBuffer?

    /// One ping-pong pair per pass that is read as a buffer, by pass id.
    private var buffers: [String: (textures: [MTLTexture], size: MTLSize)] = [:]
    private var renderedThisFrame: Set<String> = []

    // Shadertoy time: seconds since the first frame, paused time excluded.
    private var startedAt: CFTimeInterval?
    private var pausedAt: CFTimeInterval?
    private var lastFrameAt: CFTimeInterval?
    private(set) var frame = 0
    private(set) var time: Float = 0

    // Shadertoy mouse: xy the pointer while down (last position after),
    // zw the press position, z > 0 while down, w > 0 on the press frame only.
    private var mouse = SIMD4<Float>(0, 0, 0, 0)
    private var mouseDownThisFrame = false

    var onFrame: ((Float) -> Void)?

    init(program: ShaderProgram) {
        self.program = program
        uniforms = ShaderGPU.shared.device?.makeBuffer(length: ShaderTranspiler.uniformStride, options: .storageModeShared)
        super.init()
        observer = program.observe { [weak self] state in
            if case .ready(let passes) = state { self?.compiled = passes }
        }
    }

    deinit {
        if let observer { program.unobserve(observer) }
    }

    var isPaused: Bool { pausedAt != nil }

    func setPaused(_ paused: Bool) {
        if paused, pausedAt == nil {
            pausedAt = CACurrentMediaTime()
        } else if !paused, let p = pausedAt {
            // the pause is taken out of the clock; before the first frame
            // there is no clock yet
            if let s = startedAt { startedAt = s + (CACurrentMediaTime() - p) }
            pausedAt = nil
            lastFrameAt = nil
        }
    }

    /// Back to frame zero: the buffers are cleared and time starts over.
    func restart() {
        startedAt = nil
        pausedAt = nil
        lastFrameAt = nil
        frame = 0
        time = 0
        buffers = [:]
    }

    /// A touch in view points with the origin at the top left, as UIKit gives it.
    func touch(_ point: CGPoint?, in size: CGSize, scale: CGFloat, began: Bool) {
        guard let point else {
            mouse.z = -abs(mouse.z)
            mouse.w = -abs(mouse.w)
            return
        }
        let x = Float(point.x * scale)
        let y = Float((size.height - point.y) * scale)
        mouse.x = x
        mouse.y = y
        if began {
            mouse.z = x
            mouse.w = y
            mouseDownThisFrame = true
        } else {
            mouse.z = abs(mouse.z)
            mouse.w = -abs(mouse.w)
        }
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // buffers follow the drawable; a size change starts the accumulation over
        buffers = [:]
    }

    func draw(in view: MTKView) {
        guard !compiled.isEmpty, pausedAt == nil,
              let queue = ShaderGPU.shared.queue, let device = ShaderGPU.shared.device,
              let drawable = view.currentDrawable, let uniforms else { return }
        let size = view.drawableSize
        guard size.width >= 1, size.height >= 1 else { return }
        let now = CACurrentMediaTime()
        if startedAt == nil {
            startedAt = now
            MsngrLog.shader.info("shader starts: \(self.compiled.count) pass(es) at \(Int(size.width))×\(Int(size.height))")
        }
        time = Float(now - startedAt!)
        let delta = Float(lastFrameAt.map { now - $0 } ?? 1.0 / 60.0)
        lastFrameAt = now

        let mtlSize = MTLSize(width: Int(size.width), height: Int(size.height), depth: 1)
        let readAsBuffer = Set(compiled.flatMap { $0.pass.inputs.compactMap(\.bufferId) })
        for cp in compiled where readAsBuffer.contains(cp.pass.id) || cp.pass.kind == .buffer {
            ensureBuffer(cp.pass, size: mtlSize, device: device)
        }
        renderedThisFrame = []

        writeUniforms(delta: delta, size: size)
        guard let cmd = queue.makeCommandBuffer() else { return }
        for cp in compiled {
            let isImage = cp.pass.kind == .image
            let ownBuffer = buffers[cp.pass.id]
            let target: MTLTexture
            if isImage, ownBuffer == nil {
                target = drawable.texture
            } else if let ownBuffer {
                target = ownBuffer.textures[frame & 1]
            } else {
                continue
            }
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = target
            rp.colorAttachments[0].loadAction = .dontCare
            rp.colorAttachments[0].storeAction = .store
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { continue }
            enc.setRenderPipelineState(cp.pipeline)
            enc.setFragmentBuffer(uniforms, offset: 0, index: 0)
            for channel in 0..<4 {
                let input = cp.pass.input(channel)
                let tex = texture(for: input, readingFrom: cp.pass.id)
                enc.setFragmentTexture(tex, index: channel)
                enc.setFragmentSamplerState(ShaderGPU.shared.sampler(wrap: input.wrap, filter: input.filter), index: channel)
            }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
            renderedThisFrame.insert(cp.pass.id)
            if isImage, target !== drawable.texture, let blit = cmd.makeBlitCommandEncoder() {
                blit.copy(from: target, to: drawable.texture)
                blit.endEncoding()
            }
        }
        cmd.addCompletedHandler { [weak self] buffer in
            if buffer.status == .error {
                self?.program.fail(buffer.error.map { "\($0)" } ?? "command buffer error")
            }
        }
        cmd.present(drawable)
        cmd.commit()
        frame += 1
        mouseDownThisFrame = false
        onFrame?(time)
    }

    private func ensureBuffer(_ pass: ShaderPass, size: MTLSize, device: MTLDevice) {
        if let existing = buffers[pass.id], existing.size.width == size.width, existing.size.height == size.height { return }
        let format = pass.kind == .image ? Self.imageFormat : ShaderGPU.shared.bufferFormat
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size.width, height: size.height, mipmapped: false)
        d.usage = [.shaderRead, .renderTarget]
        d.storageMode = .private
        var made: [MTLTexture] = []
        for _ in 0..<2 {
            guard let t = device.makeTexture(descriptor: d) else { return }
            made.append(t)
        }
        buffers[pass.id] = (made, size)
        // a fresh buffer reads as black on the first frame, as on Shadertoy
        if let queue = ShaderGPU.shared.queue, let cmd = queue.makeCommandBuffer() {
            for t in made {
                let rp = MTLRenderPassDescriptor()
                rp.colorAttachments[0].texture = t
                rp.colorAttachments[0].loadAction = .clear
                rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                rp.colorAttachments[0].storeAction = .store
                cmd.makeRenderCommandEncoder(descriptor: rp)?.endEncoding()
            }
            cmd.commit()
        }
    }

    /// What a channel reads this frame: a pass already rendered gives its
    /// fresh texture, one not yet rendered (itself included) its previous one.
    private func texture(for input: ShaderInput, readingFrom passId: String) -> MTLTexture? {
        guard let bufferId = input.bufferId else { return ShaderGPU.shared.texture(for: input.source) }
        guard let pair = buffers[bufferId] else { return ShaderGPU.shared.texture(for: ShaderInput.none) }
        let fresh = renderedThisFrame.contains(bufferId)
        return pair.textures[fresh ? (frame & 1) : ((frame + 1) & 1)]
    }

    private func writeUniforms(delta: Float, size: CGSize) {
        guard let uniforms else { return }
        var block = [SIMD4<Float>](repeating: .zero, count: 8)
        block[0] = SIMD4(time, delta, Float(frame), 0)
        block[1] = SIMD4(Float(size.width), Float(size.height), 1, 0)
        var m = mouse
        if !mouseDownThisFrame { m.w = -abs(m.w) }
        block[2] = m
        let now = Date()
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: now)
        let secs = Float(now.timeIntervalSince(cal.startOfDay(for: now)))
        block[3] = SIMD4(Float(comps.year ?? 0), Float((comps.month ?? 1) - 1), Float(comps.day ?? 1), secs)
        for channel in 0..<4 {
            if let image = compiled.first(where: { $0.pass.kind == .image }) {
                let input = image.pass.input(channel)
                let t = texture(for: input, readingFrom: image.pass.id)
                block[4 + channel] = SIMD4(Float(t?.width ?? 0), Float(t?.height ?? 0), 1, 0)
            }
        }
        block.withUnsafeBytes { raw in
            uniforms.contents().copyMemory(from: raw.baseAddress!, byteCount: min(raw.count, uniforms.length))
        }
    }
}
