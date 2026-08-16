import UIKit
import AVFoundation
import MsngrCore

/// Voice recording: AAC at 48kbps, with waveform amplitudes produced in real time.
final class VoiceRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var duration: TimeInterval = 0
    @Published var liveAmplitudes: [Float] = []

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private(set) var fileURL: URL?

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 24000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48000,
        ]
        recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder?.isMeteringEnabled = true
        recorder?.record()
        fileURL = url
        isRecording = true
        duration = 0
        liveAmplitudes = []
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let r = self.recorder else { return }
            r.updateMeters()
            self.duration = r.currentTime
            // -60dB..0dB mapped onto 0..1
            let level = max(0, (r.averagePower(forChannel: 0) + 60) / 60)
            self.liveAmplitudes.append(level)
            if self.liveAmplitudes.count > 60 { self.liveAmplitudes.removeFirst() }
        }
    }

    /// Returns (file, duration, a waveform of 100 buckets in 0..31).
    /// Only an accidental touch of the microphone (under 0.3s) is dropped and gives nil;
    /// a short voice message like «ок» (0.3 to 1s) is a message like any other.
    func stop() -> (url: URL, duration: TimeInterval, waveform: [Int])? {
        timer?.invalidate()
        guard let r = recorder, let url = fileURL else { return nil }
        let dur = r.currentTime
        r.stop()
        recorder = nil
        isRecording = false
        guard dur >= 0.3 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return (url, dur, Self.waveform(from: url))
    }

    func cancel() {
        timer?.invalidate()
        recorder?.stop()
        recorder = nil
        isRecording = false
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
    }

    /// The file's real amplitudes reduced to 100 buckets in 0..31.
    static func waveform(from url: URL, buckets: Int = 100) -> [Int] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let format = file.processingFormat
        let totalFrames = Int(file.length)
        guard totalFrames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames)),
              (try? file.read(into: buf)) != nil,
              let data = buf.floatChannelData?[0] else { return [] }
        let frames = Int(buf.frameLength)
        let perBucket = max(frames / buckets, 1)
        var out: [Float] = []
        for b in 0..<buckets {
            let start = b * perBucket
            guard start < frames else { break }
            var peak: Float = 0
            for i in start..<min(start + perBucket, frames) {
                peak = max(peak, abs(data[i]))
            }
            out.append(peak)
        }
        let maxPeak = max(out.max() ?? 1, 0.01)
        return out.map { Int(($0 / maxPeak) * 31) }
    }
}

/// Global voice player: one per app, keeps playing across chats, speeds x1/x1.5/x2.
final class VoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = VoicePlayer()
    @Published var playingMsgId: String?
    @Published var progress: Double = 0
    @Published var rate: Float = 1.0

    private var player: AVAudioPlayer?
    private var displayLink: CADisplayLink?

    func toggle(msgId: String, url: URL) {
        if playingMsgId == msgId {
            if player?.isPlaying == true {
                player?.pause()
            } else {
                player?.play()
            }
            return
        }
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.delegate = self
        p.enableRate = true
        p.rate = rate
        p.play()
        player = p
        playingMsgId = msgId
        displayLink = CADisplayLink(target: self, selector: #selector(tick))
        displayLink?.add(to: .main, forMode: .common)
    }

    func seek(to fraction: Double) {
        guard let p = player else { return }
        p.currentTime = p.duration * fraction
    }

    func cycleRate() {
        rate = rate == 1.0 ? 1.5 : rate == 1.5 ? 2.0 : 1.0
        player?.rate = rate
    }

    func stop() {
        player?.stop()
        player = nil
        playingMsgId = nil
        progress = 0
        displayLink?.invalidate()
    }

    @objc private func tick() {
        guard let p = player, p.duration > 0 else { return }
        progress = p.currentTime / p.duration
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stop()
    }
}

/// Waveform: bars filled in as playback progresses, a tap or drag seeks.
final class WaveformView: UIView {
    var amplitudes: [Int] = [] {
        didSet { setNeedsDisplay() }
    }
    var progress: Double = 0 {
        didSet { setNeedsDisplay() }
    }
    var playedColor = UIColor(Theme.accent)
    var unplayedColor = UIColor.systemGray3
    var onSeek: ((Double) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSeek(_:)))
        addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleSeek(_:)))
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func handleSeek(_ g: UIGestureRecognizer) {
        let x = g.location(in: self).x
        onSeek?(max(0, min(1, x / bounds.width)))
    }

    override func draw(_ rect: CGRect) {
        guard !amplitudes.isEmpty, let ctx = UIGraphicsGetCurrentContext() else { return }
        let barW: CGFloat = 2.5
        let gap: CGFloat = 1.5
        let count = min(amplitudes.count, Int(bounds.width / (barW + gap)))
        let step = CGFloat(amplitudes.count) / CGFloat(count)
        let midY = bounds.midY
        for i in 0..<count {
            let amp = amplitudes[Int(CGFloat(i) * step)]
            let h = max(3, CGFloat(amp) / 31 * bounds.height)
            let x = CGFloat(i) * (barW + gap)
            let played = Double(i) / Double(count) < progress
            ctx.setFillColor((played ? playedColor : unplayedColor).cgColor)
            let bar = CGRect(x: x, y: midY - h / 2, width: barW, height: h)
            ctx.addPath(UIBezierPath(roundedRect: bar, cornerRadius: barW / 2).cgPath)
            ctx.fillPath()
        }
    }
}

/// The voice or file plate inside a bubble.
final class VoiceMessageView: UIView {
    private let playButton = UIButton(type: .system)
    private let waveform = WaveformView()
    private let durationLabel = UILabel()
    private let fileIcon = UIImageView(image: UIImage(systemName: "doc.fill"))
    private let fileName = UILabel()
    private var msg: Message?
    private var progressObservation: NSKeyValueObservation?
    private var displayTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        playButton.setImage(UIImage(systemName: "play.circle.fill"), for: .normal)
        playButton.tintColor = UIColor(Theme.accent)
        playButton.addTarget(self, action: #selector(togglePlay), for: .touchUpInside)
        durationLabel.textColor = .secondaryLabel
        fileIcon.tintColor = UIColor(Theme.accent)
        addSubview(playButton)
        addSubview(waveform)
        addSubview(durationLabel)
        addSubview(fileIcon)
        addSubview(fileName)
        waveform.onSeek = { fraction in
            VoicePlayer.shared.seek(to: fraction)
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleFileTap))
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func handleFileTap() {
        guard let msg, msg.kind == .file else { return }
        Haptics.light()
        FilePreviewPresenter.present(message: msg)
    }

    func configure(msg: Message, outgoing: Bool) {
        self.msg = msg
        durationLabel.font = Theme.Text.voiceDuration.uiFont
        fileName.font = Theme.Text.fileName.uiFont
        // accent colours are unreadable on the dark outgoing bubble
        let tint = outgoing ? UIColor(Theme.outgoingText) : UIColor(Theme.accent)
        playButton.tintColor = tint
        fileIcon.tintColor = tint
        fileName.textColor = outgoing ? UIColor(Theme.outgoingText) : .label
        durationLabel.textColor = outgoing ? UIColor(Theme.outgoingMeta) : .secondaryLabel
        waveform.playedColor = tint
        waveform.unplayedColor = outgoing
            ? UIColor(Theme.outgoingMeta).withAlphaComponent(0.5) : .systemGray3
        let isVoice = msg.kind == .voice
        playButton.isHidden = !isVoice
        waveform.isHidden = !isVoice
        fileIcon.isHidden = isVoice
        fileName.isHidden = isVoice
        if isVoice {
            waveform.amplitudes = msg.media?.waveform ?? []
            let raw = msg.media?.dur ?? 0
            if raw < 1 {
                // a sub-second voice message («ок») shows tenths: «0:00,5»
                durationLabel.text = String(format: "0:00,%01d", Int(raw * 10))
            } else {
                // rounded to the nearest second: 2.7s reads «0:03», not «0:02»
                let dur = Int(raw.rounded())
                durationLabel.text = String(format: "%d:%02d", dur / 60, dur % 60)
            }
            syncPlayingState()
            displayTimer?.invalidate()
            displayTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.syncPlayingState()
            }
        } else {
            fileName.text = msg.media?.name ?? "Файл"
            let size = msg.media?.size ?? 0
            durationLabel.text = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
    }

    private func syncPlayingState() {
        guard let msg else { return }
        let playing = VoicePlayer.shared.playingMsgId == msg.id
        playButton.setImage(UIImage(systemName: playing ? "pause.circle.fill" : "play.circle.fill"), for: .normal)
        waveform.progress = playing ? VoicePlayer.shared.progress : 0
    }

    @objc private func togglePlay() {
        guard let msg, let media = msg.media else { return }
        Haptics.light()
        Task {
            guard let mm = AppState.shared.media,
                  let url = try? await mm.fetch(media) else { return }
            // AVAudioPlayer insists on an extension, so it gets an .m4a copy
            let linked = url.deletingPathExtension().appendingPathExtension("m4a")
            if !FileManager.default.fileExists(atPath: linked.path) {
                try? FileManager.default.copyItem(at: url, to: linked)
            }
            await MainActor.run {
                VoicePlayer.shared.toggle(msgId: msg.id, url: linked)
            }
        }
    }

    // one row: play button on the left, waveform on the right, the duration small beneath
    // it; BubbleLayout puts the message time in the bottom right on the duration's line
    override func layoutSubviews() {
        super.layoutSubviews()
        playButton.frame = CGRect(x: 0, y: 1, width: 40, height: 40)
        waveform.frame = CGRect(x: 48, y: 3, width: bounds.width - 48, height: 22)
        durationLabel.frame = CGRect(x: 48, y: 27, width: 100, height: 14)
        fileIcon.frame = CGRect(x: 4, y: 5, width: 32, height: 32)
        fileName.frame = CGRect(x: 48, y: 3, width: bounds.width - 48, height: 22)
    }
}

extension VoiceMessageView: UIGestureRecognizerDelegate {
    /// Only files open a preview; a long press goes to the context menu and a double tap
    /// to the reaction.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        msg?.kind == .file
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        other is UILongPressGestureRecognizer
            || (other as? UITapGestureRecognizer)?.numberOfTapsRequired == 2
    }
}
