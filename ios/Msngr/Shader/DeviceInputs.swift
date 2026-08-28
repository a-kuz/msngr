import AVFoundation
import Accelerate
import CoreHaptics
import CoreLocation
import CoreMotion
import Metal
import UIKit
import MsngrCore

/// The phone's sensors as shader inputs. Every feed starts when the first
/// renderer that reads it takes a hold and stops when the last one lets go, so
/// a chat with no such shader spins up no sensor, asks for no permission and
/// costs no battery.
@MainActor
final class DeviceInputs {
    static let shared = DeviceInputs()

    enum Feed: Hashable {
        case motion, location, altimeter, proximity, battery, mic, camera(front: Bool), keyboard
    }

    /// What a document reads, from the names in its code and its channels.
    static func feeds(for document: ShaderDocument) -> Set<Feed> {
        var out: Set<Feed> = []
        if ["iGyro", "iAccel", "iGravity", "iMagnet", "iAttitude"].contains(where: document.references) { out.insert(.motion) }
        if document.references("iLocation") { out.insert(.location) }
        if document.references("iPressure") || document.references("iAltitude") { out.insert(.altimeter) }
        if document.references("iProximity") { out.insert(.proximity) }
        if document.references("iBattery") || document.references("iBatteryState") { out.insert(.battery) }
        for source in document.liveSources {
            switch source {
            case ShaderInput.mic: out.insert(.mic)
            case ShaderInput.camera: out.insert(.camera(front: false))
            case ShaderInput.cameraFront: out.insert(.camera(front: true))
            case ShaderInput.keyboard: out.insert(.keyboard)
            default: break
            }
        }
        return out
    }

    private var holds: [Feed: Int] = [:]

    func retain(_ feeds: Set<Feed>) {
        for f in feeds {
            holds[f, default: 0] += 1
            if holds[f] == 1 { start(f) }
        }
    }

    func release(_ feeds: Set<Feed>) {
        for f in feeds {
            guard let n = holds[f] else { continue }
            if n <= 1 { holds[f] = nil; stop(f) } else { holds[f] = n - 1 }
        }
    }

    // MARK: - Motion

    private let motion = CMMotionManager()
    private(set) var gyro = SIMD4<Float>(0, 0, 0, 0)
    private(set) var accel = SIMD4<Float>(0, 0, 0, 0)
    private(set) var gravity = SIMD4<Float>(0, 0, 0, 0)
    private(set) var magnet = SIMD4<Float>(0, 0, 0, 0)
    private(set) var attitude = SIMD4<Float>(0, 0, 0, 1)
    private(set) var heading: Float = 0

    // MARK: - Location

    private lazy var location = LocationFeed()

    // MARK: - Altimeter

    private let altimeter = CMAltimeter()
    private(set) var pressureKPa: Float = 0
    private(set) var relativeAltitude: Float = 0

    // MARK: - Mic, camera, keyboard

    private(set) var mic: MicFeed?
    private var cameras: [Bool: CameraFeed] = [:]
    let keyboard = KeyboardFeed()

    private func start(_ feed: Feed) {
        switch feed {
        case .motion:
            guard motion.isDeviceMotionAvailable else { return }
            motion.deviceMotionUpdateInterval = 1.0 / 60.0
            motion.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: .main) { [weak self] m, _ in
                guard let self, let m else { return }
                self.gyro = SIMD4(Float(m.rotationRate.x), Float(m.rotationRate.y), Float(m.rotationRate.z), 1)
                self.accel = SIMD4(Float(m.userAcceleration.x), Float(m.userAcceleration.y), Float(m.userAcceleration.z), 1)
                self.gravity = SIMD4(Float(m.gravity.x), Float(m.gravity.y), Float(m.gravity.z), 1)
                self.magnet = SIMD4(Float(m.magneticField.field.x), Float(m.magneticField.field.y), Float(m.magneticField.field.z),
                                    Float(m.magneticField.accuracy.rawValue))
                let q = m.attitude.quaternion
                self.attitude = SIMD4(Float(q.x), Float(q.y), Float(q.z), Float(q.w))
                self.heading = Float(m.heading)
            }
        case .location:
            location.start()
        case .altimeter:
            guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let self, let data else { return }
                self.pressureKPa = Float(truncating: data.pressure)
                self.relativeAltitude = Float(truncating: data.relativeAltitude)
            }
        case .proximity:
            UIDevice.current.isProximityMonitoringEnabled = true
        case .battery:
            UIDevice.current.isBatteryMonitoringEnabled = true
        case .mic:
            let m = MicFeed()
            mic = m
            m.start()
        case .camera(let front):
            let c = CameraFeed(front: front)
            cameras[front] = c
            c.start()
        case .keyboard:
            keyboard.reset()
        }
    }

    private func stop(_ feed: Feed) {
        switch feed {
        case .motion: motion.stopDeviceMotionUpdates(); gyro.w = 0
        case .location: location.stop()
        case .altimeter: altimeter.stopRelativeAltitudeUpdates()
        case .proximity: UIDevice.current.isProximityMonitoringEnabled = false
        case .battery: UIDevice.current.isBatteryMonitoringEnabled = false
        case .mic: mic?.stop(); mic = nil
        case .camera(let front): cameras[front]?.stop(); cameras[front] = nil
        case .keyboard: break
        }
    }

    // MARK: - Snapshots for the uniform block

    var locationVector: SIMD4<Float> {
        // a CLLocationManager exists only for a shader that reads the location
        guard (holds[.location] ?? 0) > 0 else { return SIMD4(0, 0, 0, heading) }
        let l = location.last
        return SIMD4(Float(l?.coordinate.latitude ?? 0), Float(l?.coordinate.longitude ?? 0),
                     Float(l?.altitude ?? 0), location.heading ?? heading)
    }

    var environmentVector: SIMD4<Float> {
        let device = UIDevice.current
        return SIMD4(pressureKPa, relativeAltitude, device.proximityState ? 1 : 0,
                     device.isBatteryMonitoringEnabled ? max(device.batteryLevel, 0) : 0)
    }

    var batteryState: Float {
        Float(UIDevice.current.isBatteryMonitoringEnabled ? UIDevice.current.batteryState.rawValue : 0)
    }

    /// The texture a live channel source shows this frame, or nil while the
    /// feed has nothing yet.
    func texture(for source: String) -> MTLTexture? {
        switch source {
        case ShaderInput.mic: return mic?.texture
        case ShaderInput.camera: return cameras[false]?.texture
        case ShaderInput.cameraFront: return cameras[true]?.texture
        case ShaderInput.keyboard: return keyboard.texture
        default: return nil
        }
    }

    /// Called once per rendered frame by the renderer that holds the keyboard.
    func frameEnded() {
        keyboard.frameEnded()
    }
}

/// CLLocationManager wants a delegate object; this is it. Asks for
/// when-in-use authorisation the first time a shader reads `iLocation`.
final class LocationFeed: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var last: CLLocation?
    private(set) var heading: Float?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func start() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        last = locations.last
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        heading = Float(newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }
}

/// The microphone as Shadertoy's sound texture: 512 columns, row 0 the FFT
/// magnitude of the latest window, row 1 the waveform, one 8-bit channel.
final class MicFeed {
    static let width = 512
    private let engine = AVAudioEngine()
    private(set) var texture: MTLTexture?
    private var fft: vDSP.FFT<DSPSplitComplex>?
    private let log2n: vDSP_Length = 10   // 1024-sample windows
    private var window = [Float](repeating: 0, count: 1024)
    private var pending = [Float]()
    private let lock = NSLock()
    private var rows = [UInt8](repeating: 0, count: 512 * 2)

    init() {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: Self.width, height: 2, mipmapped: false)
        d.usage = .shaderRead
        texture = ShaderGPU.shared.device?.makeTexture(descriptor: d)
        fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)
        vDSP_hann_window(&window, 1024, Int32(vDSP_HANN_NORM))
    }

    func start() {
        let session = AVAudioSession.sharedInstance()
        session.requestRecordPermission { [weak self] granted in
            guard granted else { return }
            DispatchQueue.main.async { self?.startEngine() }
        }
    }

    private func startEngine() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
        try? session.setActive(true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        do { try engine.start() } catch { MsngrLog.shader.error("mic: \(error.localizedDescription, privacy: .public)") }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0], buffer.frameLength >= 1024, let fft else { return }
        let n = 1024
        var samples = [Float](repeating: 0, count: n)
        vDSP_vmul(ch, 1, window, 1, &samples, 1, vDSP_Length(n))
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var magnitudes = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                samples.withUnsafeBytes { raw in
                    raw.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                fft.forward(input: split, output: &split)
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
            }
        }
        // Shadertoy's sound texture is roughly logarithmic in amplitude: a
        // quiet room reads as a low band, a voice fills the lower half
        var out = [UInt8](repeating: 0, count: Self.width * 2)
        for i in 0..<Self.width {
            let m = magnitudes[min(i, n / 2 - 1)] / 64
            let db = max(0, min(1, (log10(max(m, 1e-6)) + 3) / 3))
            out[i] = UInt8(db * 255)
            let s = ch[Int(Float(i) / Float(Self.width) * Float(buffer.frameLength))]
            out[Self.width + i] = UInt8(max(0, min(255, (s * 0.5 + 0.5) * 255)))
        }
        lock.lock(); rows = out; lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.upload() }
    }

    private func upload() {
        guard let texture else { return }
        lock.lock(); let copy = rows; lock.unlock()
        copy.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, Self.width, 2), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: Self.width)
        }
    }
}

/// A camera as a channel texture: the capture session's frames wrapped as
/// Metal textures through a CVMetalTextureCache, no copy.
final class CameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "msngr.shader.camera")
    private var cache: CVMetalTextureCache?
    private let front: Bool
    private var latest: MTLTexture?
    private let lock = NSLock()

    var texture: MTLTexture? { lock.lock(); defer { lock.unlock() }; return latest }

    init(front: Bool) {
        self.front = front
        super.init()
        if let device = ShaderGPU.shared.device {
            CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        }
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted, let self else { return }
            self.queue.async { self.configure() }
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video,
                                                   position: front ? .front : .back),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        if let connection = output.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if front, connection.isVideoMirroringSupported { connection.isVideoMirrored = true }
        }
        session.commitConfiguration()
        session.startRunning()
    }

    func stop() {
        queue.async { [session] in session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let cache, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var cvTexture: CVMetalTexture?
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixels, nil, .bgra8Unorm, w, h, 0, &cvTexture)
        guard let cvTexture, let t = CVMetalTextureGetTexture(cvTexture) else { return }
        lock.lock(); latest = t; lock.unlock()
    }
}

/// Shadertoy's keyboard texture: 256 key codes across, three rows down.
/// Row 0 is 1 while the key is held, row 1 is 1 for the frame it went down,
/// row 2 flips on every press. Fed by the hardware key events of the canvas
/// that has the keyboard focus.
final class KeyboardFeed {
    private(set) var texture: MTLTexture?
    private var held = [UInt8](repeating: 0, count: 256)
    private var pressed = [UInt8](repeating: 0, count: 256)
    private var toggled = [UInt8](repeating: 0, count: 256)
    private var dirty = true

    init() {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 256, height: 3, mipmapped: false)
        d.usage = .shaderRead
        texture = ShaderGPU.shared.device?.makeTexture(descriptor: d)
    }

    func reset() {
        held = [UInt8](repeating: 0, count: 256)
        pressed = held
        toggled = held
        dirty = true
    }

    /// JavaScript key codes, which is what Shadertoy indexes by: letters and
    /// digits share ASCII, arrows are 37–40, space 32, enter 13, escape 27.
    func keyDown(_ press: UIPress) {
        guard let code = Self.jsKeyCode(press) else { return }
        if held[code] == 0 { pressed[code] = 255; toggled[code] = toggled[code] == 0 ? 255 : 0 }
        held[code] = 255
        dirty = true
    }

    func keyUp(_ press: UIPress) {
        guard let code = Self.jsKeyCode(press) else { return }
        held[code] = 0
        dirty = true
    }

    /// The "pressed this frame" row is cleared once a frame has read it.
    func frameEnded() {
        if pressed.contains(where: { $0 != 0 }) {
            pressed = [UInt8](repeating: 0, count: 256)
            dirty = true
        }
        upload()
    }

    private func upload() {
        guard dirty, let texture else { return }
        dirty = false
        let all = held + pressed + toggled
        all.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, 256, 3), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: 256)
        }
    }

    static func jsKeyCode(_ press: UIPress) -> Int? {
        guard let key = press.key else { return nil }
        switch key.keyCode {
        case .keyboardLeftArrow: return 37
        case .keyboardUpArrow: return 38
        case .keyboardRightArrow: return 39
        case .keyboardDownArrow: return 40
        case .keyboardSpacebar: return 32
        case .keyboardReturnOrEnter: return 13
        case .keyboardEscape: return 27
        case .keyboardLeftShift, .keyboardRightShift: return 16
        case .keyboardLeftControl, .keyboardRightControl: return 17
        case .keyboardLeftAlt, .keyboardRightAlt: return 18
        default:
            let s = key.charactersIgnoringModifiers.uppercased()
            guard let scalar = s.unicodeScalars.first, scalar.value < 256 else { return nil }
            return Int(scalar.value)
        }
    }
}

/// The haptic engine driven from a shader: the image pass writes the
/// intensity and the sharpness it wants into fragment (0, 0), the renderer
/// reads the texel back after the frame and hands it here.
@MainActor
final class ShaderHaptics {
    static let shared = ShaderHaptics()
    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    private var lastIntensity: Float = 0

    private init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        engine = try? CHHapticEngine()
        engine?.resetHandler = { [weak self] in
            try? self?.engine?.start()
            self?.player = nil
        }
        try? engine?.start()
    }

    /// Intensity 0 stops the vibration; anything above keeps a continuous
    /// event running with the parameters updated every frame.
    func drive(intensity: Float, sharpness: Float) {
        guard let engine else { return }
        let i = max(0, min(1, intensity))
        if i == 0 {
            if lastIntensity > 0 { try? player?.stop(atTime: 0); player = nil }
            lastIntensity = 0
            return
        }
        if player == nil {
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: i),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: max(0, min(1, sharpness))),
            ], relativeTime: 0, duration: 30)
            guard let pattern = try? CHHapticPattern(events: [event], parameters: []),
                  let p = try? engine.makeAdvancedPlayer(with: pattern) else { return }
            try? p.start(atTime: 0)
            player = p
        } else {
            let params = [
                CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: i, relativeTime: 0),
                CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: max(0, min(1, sharpness)), relativeTime: 0),
            ]
            try? player?.sendParameters(params, atTime: 0)
        }
        lastIntensity = i
    }
}
