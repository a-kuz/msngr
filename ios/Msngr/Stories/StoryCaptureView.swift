import SwiftUI
import AVFoundation
import Photos
import UIKit

/// The camera a story starts on: the front camera filling the screen, a shutter
/// that takes a picture on a tap and records while it is held, the library one
/// tap away at the bottom with the last picture on it, and the other camera one
/// tap — or a double tap on the picture — away. A pinch zooms, a tap focuses,
/// the flash cycles at the top, and a swipe up opens the library. Where there is
/// no camera at all — the simulator — the screen says so and the library still
/// works.
struct StoryCaptureView: View {
    let onPhoto: (UIImage) -> Void
    let onVideo: (URL) -> Void
    let onLibrary: () -> Void

    @StateObject private var camera = StoryCamera()
    @State private var pressing = false
    @State private var lastPicture: UIImage?
    @State private var focusPoint: CGPoint?
    @State private var focusShown = false
    @State private var zoomStart: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.available {
                CameraPreview(session: camera.session) { layer in camera.attach(layer) }
                    .ignoresSafeArea()
                    .accessibilityIdentifier("story.preview")
                    .simultaneousGesture(
                        MagnifyGesture()
                            .onChanged { value in camera.zoom(to: zoomStart * value.magnification) }
                            .onEnded { _ in zoomStart = camera.zoomFactor }
                    )
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 40)
                            .onEnded { value in
                                if value.translation.height < -80, abs(value.translation.width) < 60 { onLibrary() }
                            }
                    )
                    .onTapGesture(count: 2) { camera.flip(); zoomStart = 1 }
                    .onTapGesture { point in
                        camera.focus(atLayerPoint: point)
                        focusPoint = point
                        withAnimation(.easeOut(duration: 0.15)) { focusShown = true }
                        Task {
                            try? await Task.sleep(for: .milliseconds(900))
                            withAnimation(.easeIn(duration: 0.2)) { focusShown = false }
                        }
                    }
                if let focusPoint, focusShown {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.yellow, lineWidth: 1.5)
                        .frame(width: 72, height: 72)
                        .position(focusPoint)
                        .transition(.scale(scale: 1.4).combined(with: .opacity))
                        .allowsHitTesting(false)
                        .ignoresSafeArea()
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.white.opacity(0.5))
                    Text("Camera unavailable")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .accessibilityIdentifier("story.noCamera")
            }
            VStack {
                HStack {
                    Spacer()
                    if camera.available && camera.hasFlash && !camera.isRecording {
                        Button { camera.cycleFlash() } label: {
                            Image(systemName: camera.flash == .off ? "bolt.slash.fill"
                                  : camera.flash == .on ? "bolt.fill" : "bolt.badge.automatic.fill")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(camera.flash == .off ? .white : .yellow)
                                .frame(width: 40, height: 40)
                                .background(.black.opacity(0.35), in: Circle())
                        }
                        .accessibilityIdentifier("story.flash")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                Spacer()
                if camera.isRecording {
                    Text(timeText)
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.red, in: Capsule())
                        .padding(.bottom, 18)
                        .accessibilityIdentifier("story.recordingTime")
                }
                if camera.zoomFactor > 1.05 && !camera.isRecording {
                    Text(String(format: "%.1f×", camera.zoomFactor))
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.4), in: Capsule())
                        .padding(.bottom, 18)
                        .accessibilityIdentifier("story.zoom")
                }
                HStack {
                    libraryButton
                        .opacity(camera.isRecording ? 0 : 1)
                    Spacer()
                    shutter
                    Spacer()
                    Button { camera.flip(); zoomStart = 1 } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(.white.opacity(0.18), in: Circle())
                    }
                    .accessibilityIdentifier("story.flip")
                    .opacity(camera.available && !camera.isRecording ? 1 : 0)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
        .onAppear {
            camera.capHit = { [weak camera] in
                camera?.stopRecording { url in if let url { onVideo(url) } }
            }
            camera.start()
            Task { lastPicture = await LastPicture.load() }
        }
        .onDisappear { camera.stop() }
    }

    /// The library, wearing the last picture taken when the library may be read.
    private var libraryButton: some View {
        Button(action: onLibrary) {
            Group {
                if let lastPicture {
                    Image(uiImage: lastPicture)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo.on.rectangle")
                        .font(.title2)
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 48, height: 48)
            .background(.white.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.8), lineWidth: 1.5))
        }
        .accessibilityIdentifier("story.library")
    }

    /// A tap takes a picture; a hold records for as long as the finger stays,
    /// up to the cap, and the ring around the button fills as the cap nears.
    private var shutter: some View {
        ZStack {
            Circle()
                .stroke(.white, lineWidth: 4)
                .frame(width: 78, height: 78)
            if camera.isRecording {
                Circle()
                    .trim(from: 0, to: camera.duration / StoryCamera.maximumTake)
                    .stroke(.red, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 78, height: 78)
                    .animation(.linear(duration: 0.1), value: camera.duration)
            }
            Circle()
                .fill(camera.isRecording ? .red : .white)
                .frame(width: camera.isRecording ? 40 : 64, height: camera.isRecording ? 40 : 64)
                .scaleEffect(pressing && !camera.isRecording ? 0.9 : 1)
                .animation(.spring(duration: 0.2), value: camera.isRecording)
                .animation(.spring(duration: 0.15), value: pressing)
        }
        .frame(width: 92, height: 92)
        .contentShape(Circle())
        .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 60) {
            camera.startRecording()
        } onPressingChanged: { down in
            pressing = down
            guard !down else { return }
            if camera.isRecording {
                camera.stopRecording { url in if let url { onVideo(url) } }
            } else {
                camera.capturePhoto { image in if let image { onPhoto(image) } }
            }
        }
        .disabled(!camera.available)
        .accessibilityIdentifier("story.shutter")
        .accessibilityLabel(Text("Shutter"))
    }

    private var timeText: String {
        let total = Int(camera.duration)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The newest picture in the library, read only where reading was already
/// allowed: the camera never asks for the library on its own.
enum LastPicture {
    static func load() async -> UIImage? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        guard let asset = PHAsset.fetchAssets(with: options).firstObject else { return nil }
        return await withCheckedContinuation { cont in
            let request = PHImageRequestOptions()
            request.deliveryMode = .fastFormat
            request.isNetworkAccessAllowed = false
            var delivered = false
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 144, height: 144),
                                                  contentMode: .aspectFill, options: request) { image, _ in
                guard !delivered else { return }
                delivered = true
                cont.resume(returning: image)
            }
        }
    }
}

/// The story camera: one session with the picture and the movie outputs on it,
/// the front camera first, the microphone joined for the sound of a clip.
@MainActor
final class StoryCamera: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var duration: TimeInterval = 0
    /// False where no camera exists to build a session from.
    @Published private(set) var available = AVCaptureDevice.default(for: .video) != nil
    @Published private(set) var flash: AVCaptureDevice.FlashMode = .off
    @Published private(set) var hasFlash = false
    @Published private(set) var zoomFactor: CGFloat = 1

    let session = AVCaptureSession()
    static let maximumTake: TimeInterval = 60

    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var position: AVCaptureDevice.Position = .front
    private var configured = false
    private var timer: Timer?
    private var photoHandler: ((UIImage?) -> Void)?
    private var movieHandler: ((URL?) -> Void)?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?

    private var device: AVCaptureDevice? { videoInput?.device }

    func attach(_ layer: AVCaptureVideoPreviewLayer) { previewLayer = layer }

    /// Asks for the camera and the microphone, then spins the session up off
    /// the main thread; the preview lights the moment it runs.
    func start() {
        guard available else { return }
        Task {
            guard await CameraGate.requestPermission() else {
                available = false
                return
            }
            guard configure() else {
                available = false
                return
            }
            let session = self.session
            await Task.detached {
                if !session.isRunning { session.startRunning() }
            }.value
        }
    }

    func stop() {
        timer?.invalidate()
        // a take still running is dropped; one already stopping keeps its
        // handler and lands where the finger sent it
        if isRecording, movieOutput.isRecording {
            movieHandler = { url in if let url { try? FileManager.default.removeItem(at: url) } }
            movieOutput.stopRecording()
        }
        isRecording = false
        setTorch(false)
        let session = self.session
        Task.detached {
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure() -> Bool {
        guard !configured else { return true }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high
        guard attachCamera(at: position) else { return false }
        if let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }
        guard session.canAddOutput(photoOutput), session.canAddOutput(movieOutput) else { return false }
        session.addOutput(photoOutput)
        session.addOutput(movieOutput)
        orientConnections()
        configured = true
        return true
    }

    /// Swaps the camera input for the one at `position`; the outputs stay.
    private func attachCamera(at position: AVCaptureDevice.Position) -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        if let old = videoInput { session.removeInput(old) }
        guard session.canAddInput(input) else {
            if let old = videoInput, session.canAddInput(old) { session.addInput(old) }
            return false
        }
        session.addInput(input)
        videoInput = input
        self.position = position
        hasFlash = device.hasFlash
        zoomFactor = 1
        return true
    }

    /// Portrait, and mirrored on the front camera so the picture matches the
    /// preview the sender framed it in.
    private func orientConnections() {
        for output in [photoOutput as AVCaptureOutput, movieOutput] {
            guard let conn = output.connection(with: .video) else { continue }
            if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
            if conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = position == .front
            }
        }
    }

    func flip() {
        guard configured, !isRecording else { return }
        let other: AVCaptureDevice.Position = position == .front ? .back : .front
        session.beginConfiguration()
        _ = attachCamera(at: other)
        orientConnections()
        session.commitConfiguration()
        Haptics.light()
    }

    func cycleFlash() {
        switch flash {
        case .off: flash = .auto
        case .auto: flash = .on
        default: flash = .off
        }
    }

    /// The zoom, held within what the lens can do; the number shown is the
    /// factor over the lens's own field.
    func zoom(to factor: CGFloat) {
        guard let device else { return }
        let top = min(device.activeFormat.videoMaxZoomFactor, 8)
        let clamped = min(max(factor, 1), top)
        guard (try? device.lockForConfiguration()) != nil else { return }
        device.videoZoomFactor = clamped
        device.unlockForConfiguration()
        zoomFactor = clamped
    }

    /// Focus and exposure on the tapped spot, then back to continuous once the
    /// scene moves on.
    func focus(atLayerPoint point: CGPoint) {
        guard let device, let previewLayer else { return }
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: point)
        guard (try? device.lockForConfiguration()) != nil else { return }
        if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
            device.focusPointOfInterest = devicePoint
            device.focusMode = .autoFocus
        }
        if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
            device.exposurePointOfInterest = devicePoint
            device.exposureMode = .autoExpose
        }
        device.isSubjectAreaChangeMonitoringEnabled = true
        device.unlockForConfiguration()
    }

    private func setTorch(_ on: Bool) {
        guard let device, device.hasTorch else { return }
        guard (try? device.lockForConfiguration()) != nil else { return }
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
    }

    func capturePhoto(_ completion: @escaping (UIImage?) -> Void) {
        guard configured, session.isRunning, photoHandler == nil else { completion(nil); return }
        photoHandler = completion
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        if hasFlash, photoOutput.supportedFlashModes.contains(flash) { settings.flashMode = flash }
        photoOutput.capturePhoto(with: settings, delegate: self)
        Haptics.light()
    }

    func startRecording() {
        guard configured, session.isRunning, !movieOutput.isRecording else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .videoRecording,
                                                         options: [.defaultToSpeaker, .allowBluetoothHFP])
        try? AVAudioSession.sharedInstance().setActive(true)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("story-take-\(UUID().uuidString).mov")
        isRecording = true
        duration = 0
        // the flash, for a clip, is the torch for as long as the take runs
        if flash != .off { setTorch(true) }
        movieOutput.startRecording(to: url, recordingDelegate: self)
        Haptics.medium()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.duration += 0.1
                if self.duration >= Self.maximumTake { self.capHit?() }
            }
        }
    }

    /// Set by the screen: the cap ends the take the way lifting the finger does.
    var capHit: (() -> Void)?

    func stopRecording(_ completion: @escaping (URL?) -> Void) {
        timer?.invalidate()
        guard isRecording else { completion(nil); return }
        isRecording = false
        setTorch(false)
        movieHandler = { url in
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            completion(url)
        }
        if movieOutput.isRecording {
            movieOutput.stopRecording()
        } else {
            movieHandler = nil
            completion(nil)
        }
    }
}

extension StoryCamera: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        let image = photo.fileDataRepresentation().flatMap(UIImage.init(data:))
        Task { @MainActor in
            let handler = photoHandler
            photoHandler = nil
            handler?(error == nil ? image : nil)
        }
    }
}

extension StoryCamera: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        let reachable = (try? outputFileURL.checkResourceIsReachable()) == true
        Task { @MainActor in
            let handler = movieHandler
            movieHandler = nil
            handler?(error == nil || reachable ? outputFileURL : nil)
        }
    }
}

/// The preview layer, filling whatever frame it is given.
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let onLayer: (AVCaptureVideoPreviewLayer) -> Void

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        onLayer(view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
