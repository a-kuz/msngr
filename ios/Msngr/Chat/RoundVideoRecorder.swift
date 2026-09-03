import UIKit
import AVFoundation
import SwiftUI
import Combine
import MsngrCore

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
    /// Every touch of the session goes through this one queue: the session is not
    /// safe to configure from two threads, and startRunning blocks while the
    /// hardware spins up.
    private let sessionQueue = DispatchQueue(label: "msngr.round-video.session")
    /// The layer the live circle draws, made with the session and never pointed
    /// at it again. The circle appears only once a take is running, and pointing
    /// a layer at a recording session reconfigures it, which ends the take with
    /// no file written.
    let previewLayer: AVCaptureVideoPreviewLayer

    private let output = AVCaptureMovieFileOutput()
    /// Whether a file was asked for. `output.isRecording` turns true only once the
    /// first sample is written, so it cannot answer this right after the start.
    /// Touched on the session queue only.
    private var takeRequested = false
    private var timer: Timer?
    private var configured = false
    private var finish: ((URL?) -> Void)?
    /// Set while the finger is up but the take runs on: the cap ends it.
    static let maximumTake: TimeInterval = 60
    /// A touch shorter than this is an accident, the same cut the voice takes.
    static let minimumTake: TimeInterval = 0.3

    static func isAccidental(_ duration: TimeInterval) -> Bool { duration < minimumTake }

    override init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init()
        previewLayer.videoGravity = .resizeAspectFill
    }

    struct CameraUnavailable: Error {}

    /// Builds the session once: the front camera, the microphone, the movie
    /// output. Throws where there is no camera to build from.
    private func configureIfNeeded() throws {
        guard !configured else { return }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let cameraInput = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(cameraInput) else { throw CameraUnavailable() }
        session.beginConfiguration()
        session.sessionPreset = .high
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
                                                        options: [.defaultToSpeaker, .allowBluetoothHFP])
        try AVAudioSession.sharedInstance().setActive(true)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("round-\(UUID().uuidString).mov")
        isRecording = true
        duration = 0
        finish = nil
        // the recording starts the moment the session reports running, from the
        // session's own queue: startRecording takes the session lock, and the main
        // thread must never wait on it
        sessionQueue.async { [session, output] in
            if !session.isRunning { session.startRunning() }
            let stillWanted = DispatchQueue.main.sync { self.isRecording }
            guard stillWanted else { return }   // cancelled while spinning up
            self.takeRequested = true
            output.startRecording(to: url, recordingDelegate: self)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.duration += 0.1
            if self.duration >= Self.maximumTake { self.hitCap() }
        }
    }

    /// The cap ends the take the way the finger would: the file is kept and sent.
    var onCap: (() -> Void)?
    /// A take that ended by itself, before the finger asked: the screen resets
    /// its gesture and says the video was not recorded.
    var onFailure: (() -> Void)?

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
        if Self.isAccidental(duration) {
            discardTake()
            completion(nil)
            return
        }
        finish = { [weak self] url in
            self?.teardown()
            completion(url)
        }
        // the stop is queued behind the start, so the take is asked to end only
        // where one was actually asked for
        sessionQueue.async { [output] in
            guard self.takeRequested else {
                DispatchQueue.main.async { [weak self] in
                    self?.finish = nil
                    self?.teardown()
                    completion(nil)
                }
                return
            }
            self.takeRequested = false
            output.stopRecording()
        }
    }

    /// Ends a take nobody wants: the file, if one was started, goes with it.
    private func discardTake() {
        finish = { url in if let url { try? FileManager.default.removeItem(at: url) } }
        sessionQueue.async { [output] in
            guard self.takeRequested else { return }
            self.takeRequested = false
            output.stopRecording()
        }
        teardown()
    }

    func cancel() {
        timer?.invalidate()
        isRecording = false
        discardTake()
    }

    /// The camera light goes off and the audio session is given back the moment
    /// the take ends; held on, they outlive the bubble the take became.
    private func teardown() {
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

extension RoundVideoRecorder: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        let size = (try? FileManager.default.attributesOfItem(atPath: outputFileURL.path)[.size] as? Int) ?? nil
        DispatchQueue.main.async { [weak self] in
            let handler = self?.finish
            self?.finish = nil
            // an errored take can still leave a file behind, empty or truncated:
            // handing it on turns into a bubble nothing can play
            if let error {
                MsngrLog.outbox.error("round video take failed: \(error), file \(size ?? -1) bytes")
                try? FileManager.default.removeItem(at: outputFileURL)
                if handler == nil { self?.failedUnasked() } else { handler?(nil) }
                return
            }
            guard let size, size > 0 else {
                MsngrLog.outbox.error("round video take produced an empty file")
                try? FileManager.default.removeItem(at: outputFileURL)
                if handler == nil { self?.failedUnasked() } else { handler?(nil) }
                return
            }
            handler?(outputFileURL)
        }
    }

    /// The take ended with nobody waiting for it: the camera failed on its own
    /// while the finger was still down. The session is given back here; held on,
    /// its light stays on for as long as the app lives.
    private func failedUnasked() {
        guard isRecording else { return }
        isRecording = false
        timer?.invalidate()
        sessionQueue.async { self.takeRequested = false }
        teardown()
        onFailure?()
    }
}

/// The live circle over the feed while a round video records: the front camera
/// in a ring, the same diameter the sent bubble will have.
struct RoundRecordingPreview: View {
    @ObservedObject var recorder: RoundVideoRecorder

    var body: some View {
        CameraCircle(previewLayer: recorder.previewLayer)
            .frame(width: BubbleLayout.roundVideoSide * 1.25,
                   height: BubbleLayout.roundVideoSide * 1.25)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 2))
            .shadow(radius: 14)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
            .accessibilityIdentifier("chat.roundVideoPreview")
    }
}

/// The recorder's preview layer, hosted for SwiftUI. The view only carries the
/// layer around and gives it its bounds; the layer's session is set once, where
/// the layer is made.
private struct CameraCircle: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    final class PreviewView: UIView {
        private let previewLayer: AVCaptureVideoPreviewLayer

        init(previewLayer: AVCaptureVideoPreviewLayer) {
            self.previewLayer = previewLayer
            super.init(frame: .zero)
            layer.addSublayer(previewLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer.frame = bounds
        }
    }

    func makeUIView(context: Context) -> PreviewView { PreviewView(previewLayer: previewLayer) }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
