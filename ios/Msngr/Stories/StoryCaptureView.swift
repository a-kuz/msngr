import SwiftUI
import AVFoundation
import UIKit

/// The camera a story starts on: the front camera filling the screen, a shutter
/// that takes a picture on a tap and records while it is held, the library one
/// tap away at the bottom, and the other camera one tap away beside it. Where
/// there is no camera at all — the simulator — the screen says so and the
/// library still works.
struct StoryCaptureView: View {
    let onPhoto: (UIImage) -> Void
    let onVideo: (URL) -> Void
    let onLibrary: () -> Void

    @StateObject private var camera = StoryCamera()
    @State private var pressing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.available {
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()
                    .accessibilityIdentifier("story.preview")
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
                HStack {
                    Button(action: onLibrary) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .accessibilityIdentifier("story.library")
                    .opacity(camera.isRecording ? 0 : 1)
                    Spacer()
                    shutter
                    Spacer()
                    Button { camera.flip() } label: {
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
        }
        .onDisappear { camera.stop() }
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

/// The story camera: one session with the picture and the movie outputs on it,
/// the front camera first, the microphone joined for the sound of a clip.
@MainActor
final class StoryCamera: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var duration: TimeInterval = 0
    /// False where no camera exists to build a session from.
    @Published private(set) var available = AVCaptureDevice.default(for: .video) != nil

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
    }

    func capturePhoto(_ completion: @escaping (UIImage?) -> Void) {
        guard configured, session.isRunning, photoHandler == nil else { completion(nil); return }
        photoHandler = completion
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        photoOutput.capturePhoto(with: settings, delegate: self)
        Haptics.light()
    }

    func startRecording() {
        guard configured, session.isRunning, !movieOutput.isRecording else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .videoRecording,
                                                         options: [.defaultToSpeaker, .allowBluetooth])
        try? AVAudioSession.sharedInstance().setActive(true)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("story-take-\(UUID().uuidString).mov")
        isRecording = true
        duration = 0
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

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
