import UIKit
import AVFoundation
import SwiftUI
import Combine

/// What a touch of the camera button may do, the same rule MicGate holds for
/// the microphone: ask first, record after. The camera needs both permissions —
/// a round video with no sound track would arrive broken.
enum CameraGate {
    static func requestPermission() async -> Bool {
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: granted = true
        case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .video)
        default: granted = false
        }
        guard granted else { return false }
        return await VoiceRecorder.requestPermission()
    }
}

/// Round video recording: the front camera and the microphone into an mp4,
/// driven by the same RecordingGesture the voice button uses. The takes are
/// capped — a circle is a short format, and the cap is what ends a locked
/// recording nobody is holding.
final class RoundVideoRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var duration: TimeInterval = 0

    /// The circle the sender watches while recording; owned here so the preview
    /// survives the SwiftUI view updates around it.
    let session = AVCaptureSession()

    private let output = AVCaptureMovieFileOutput()
    private var timer: Timer?
    private var configured = false
    private var finish: ((URL?) -> Void)?
    /// Set while the finger is up but the take runs on: the cap ends it.
    static let maximumTake: TimeInterval = 60
    /// A touch shorter than this is an accident, the same cut the voice takes.
    static let minimumTake: TimeInterval = 0.3

    static func isAccidental(_ duration: TimeInterval) -> Bool { duration < minimumTake }

    struct CameraUnavailable: Error {}

    /// Builds the session once: the front camera, the microphone, the movie
    /// output. Throws where there is no camera to build from.
    private func configureIfNeeded() throws {
        guard !configured else { return }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let cameraInput = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(cameraInput) else { throw CameraUnavailable() }
        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        session.addInput(cameraInput)
        if let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CameraUnavailable()
        }
        session.addOutput(output)
        // the sender sees themselves mirrored in the preview; the file matches,
        // or the received circle shows a stranger's mirror image of the room
        if let conn = output.connection(with: .video), conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = true
        }
        session.commitConfiguration()
        configured = true
    }

    func start() throws {
        try configureIfNeeded()
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .videoRecording,
                                                        options: [.defaultToSpeaker, .allowBluetooth])
        try AVAudioSession.sharedInstance().setActive(true)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("round-\(UUID().uuidString).mov")
        isRecording = true
        duration = 0
        // startRunning blocks while the hardware spins up; off the main thread,
        // with the recording started the moment the session reports running
        Task.detached { [session, output] in
            if !session.isRunning { session.startRunning() }
            await MainActor.run {
                guard self.isRecording else { return }   // cancelled while spinning up
                output.startRecording(to: url, recordingDelegate: self)
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.duration += 0.1
            if self.duration >= Self.maximumTake { self.hitCap() }
        }
    }

    /// The cap ends the take the way the finger would: the file is kept and sent.
    var onCap: (() -> Void)?

    private func hitCap() {
        guard isRecording else { return }
        onCap?()
    }

    /// Stops and hands the file over; an accidental touch gives nothing back
    /// and takes its file with it.
    func stop(completion: @escaping (URL?) -> Void) {
        timer?.invalidate()
        guard isRecording else { completion(nil); return }
        isRecording = false
        let dur = duration
        guard !Self.isAccidental(dur), output.isRecording else {
            if output.isRecording {
                finish = { url in if let url { try? FileManager.default.removeItem(at: url) } }
                output.stopRecording()
            }
            teardown()
            completion(nil)
            return
        }
        finish = { [weak self] url in
            self?.teardown()
            completion(url)
        }
        output.stopRecording()
    }

    func cancel() {
        timer?.invalidate()
        isRecording = false
        if output.isRecording {
            finish = { url in if let url { try? FileManager.default.removeItem(at: url) } }
            output.stopRecording()
        }
        teardown()
    }

    /// The camera light goes off and the audio session is given back the moment
    /// the take ends; held on, they outlive the bubble the take became.
    private func teardown() {
        Task.detached { [session] in
            if session.isRunning { session.stopRunning() }
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

extension RoundVideoRecorder: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async { [weak self] in
            let handler = self?.finish
            self?.finish = nil
            if error != nil, (try? outputFileURL.checkResourceIsReachable()) != true {
                handler?(nil)
                return
            }
            handler?(outputFileURL)
        }
    }
}

/// The live circle over the feed while a round video records: the front camera
/// in a ring, the same diameter the sent bubble will have.
struct RoundRecordingPreview: View {
    @ObservedObject var recorder: RoundVideoRecorder

    var body: some View {
        CameraCircle(session: recorder.session)
            .frame(width: BubbleLayout.roundVideoSide * 1.25,
                   height: BubbleLayout.roundVideoSide * 1.25)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 2))
            .shadow(radius: 14)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
            .accessibilityIdentifier("chat.roundVideoPreview")
    }
}

/// The AVCaptureVideoPreviewLayer wrapped for SwiftUI.
private struct CameraCircle: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
