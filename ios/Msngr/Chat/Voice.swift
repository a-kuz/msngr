import UIKit
import AVFoundation
import Combine
import MsngrCore

/// What a tap on the microphone does. Kept apart from the recording itself so that
/// the "ask first, record after" rule holds on its own: a recording started under the
/// system dialog captures silence, and after a refusal captures nothing at all, which
/// with no explanation looks like a broken button.
enum MicGate {
    enum Permission { case granted, denied, undetermined }
    enum Decision: Equatable {
        case record   // permission is granted
        case ask      // ask, and record according to the answer
        case explain  // refused: there will be no dialog again, point at Settings
    }

    static func decide(_ permission: Permission) -> Decision {
        switch permission {
        case .granted: return .record
        case .undetermined: return .ask
        case .denied: return .explain
        }
    }

    static var current: Permission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        default: return .undetermined
        }
    }
}

/// What the finger on the microphone does with the take. Kept apart from the view
/// because the rules only hold together: access is asked for asynchronously, so a take
/// can become allowed after the finger has already left, and a take dropped by the
/// slide must not be started again by the same finger still moving over the button.
struct RecordingGesture {
    enum Phase: Equatable { case idle, waiting, recording, locked, cancelled }
    enum Action: Equatable {
        case none
        case ask      // ask for the microphone, then report the answer back
        case start    // the finger is still down: the recorder may run
        case lock
        case cancel   // drop the take along with its file
        case finish   // stop, and send it if it is long enough
    }

    /// Sliding this far left drops the take, this far up locks it (in points).
    static let cancelDistance: CGFloat = 110
    static let lockDistance: CGFloat = 70

    private(set) var phase: Phase = .idle

    var isLocked: Bool { phase == .locked }

    mutating func touchDown() -> Action {
        guard phase == .idle else { return .none }
        phase = .waiting
        return .ask
    }

    /// The answer to the microphone request. A take nobody is holding any more never
    /// starts: an accidental touch leaves no file and no message behind it.
    mutating func permitted(_ granted: Bool) -> Action {
        guard phase == .waiting else { return .none }
        guard granted else {
            phase = .idle
            return .none
        }
        phase = .recording
        return .start
    }

    mutating func moved(_ translation: CGSize) -> Action {
        switch phase {
        case .waiting:
            // the finger is already leaving: the take being asked for is dropped
            if translation.width < -Self.cancelDistance { phase = .cancelled }
            return .none
        case .recording:
            if translation.width < -Self.cancelDistance {
                phase = .cancelled
                return .cancel
            }
            if translation.height < -Self.lockDistance {
                phase = .locked
                return .lock
            }
            return .none
        case .idle, .locked, .cancelled:
            return .none
        }
    }

    mutating func touchUp() -> Action {
        switch phase {
        case .recording:
            phase = .idle
            return .finish
        case .waiting, .cancelled:
            phase = .idle
            return .none
        case .idle, .locked:
            return .none
        }
    }

    /// The buttons a locked take gets instead of the finger.
    mutating func send() -> Action {
        phase = .idle
        return .finish
    }

    mutating func discard() -> Action {
        phase = .idle
        return .cancel
    }

    /// The screen goes away, the app leaves the foreground, a call comes in: the take is
    /// dropped whole instead of being sent as a stump of whatever was said before.
    mutating func interrupted() -> Action {
        let wasLive = phase == .recording || phase == .locked
        phase = .idle
        return wasLive ? .cancel : .none
    }
}

/// Voice recording: AAC at 48kbps, with waveform amplitudes produced in real time.
final class VoiceRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var duration: TimeInterval = 0
    @Published var liveAmplitudes: [Float] = []

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private(set) var fileURL: URL?

    /// Microphone access. It is asked for before recording rather than alongside it:
    /// the system dialog covers the screen, and a take started underneath it would be
    /// silence. A refusal is a state the screen reports, not a recording error.
    static func requestPermission() async -> Bool {
        switch MicGate.decide(MicGate.current) {
        case .record: return true
        case .explain: return false
        case .ask: return await AVAudioApplication.requestRecordPermission()
        }
    }

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

    /// A touch of the microphone shorter than this is an accident. A quick "ok" of half a
    /// second is a message like any other, so the cut sits below it.
    static let minimumTake: TimeInterval = 0.3

    static func isAccidental(_ duration: TimeInterval) -> Bool { duration < minimumTake }

    /// Returns (file, duration, a waveform of 100 buckets in 0..31); an accidental touch
    /// gives nothing back and takes its file with it.
    func stop() -> (url: URL, duration: TimeInterval, waveform: [Int])? {
        timer?.invalidate()
        guard let r = recorder, let url = fileURL else { return nil }
        let dur = r.currentTime
        r.stop()
        recorder = nil
        fileURL = nil
        isRecording = false
        releaseSession()
        guard !Self.isAccidental(dur) else {
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
        fileURL = nil
        releaseSession()
    }

    /// The recording session is given back at once: held on, it keeps the red bar up and
    /// leaves other apps ducked long after the take is over.
    private func releaseSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
            let end = min(start + perBucket, frames)
            var sum: Float = 0
            for i in start..<end { sum += data[i] * data[i] }
            out.append((sum / Float(end - start)).squareRoot())
        }
        return normalize(out)
    }

    /// Loudness per bucket into the 0…31 the wave is drawn from. The scale is
    /// the 95th percentile rather than the loudest bucket: one click at the
    /// start of a take would otherwise flatten all the speech after it. The
    /// square root lifts quiet speech, so a calm voice still reads as a wave.
    static func normalize(_ levels: [Float]) -> [Int] {
        guard !levels.isEmpty else { return [] }
        let sorted = levels.sorted()
        let ceiling = max(sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], 0.001)
        return levels.map { Int((min($0 / ceiling, 1).squareRoot() * 31).rounded()) }
    }
}

/// What the bubbles draw: which message the player is on, whether it is running right
/// now, how far it has got and at what speed. One value rather than four so that a
/// subscriber sees a whole state instead of three stale fields and one fresh one.
struct VoicePlayback: Equatable {
    var msgId: String?
    var isPlaying = false
    var progress: Double = 0
    var rate: Float = 1.0
}

/// Global voice player: one per app, keeps playing across chats, speeds x1/x1.5/x2.
final class VoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = VoicePlayer()
    @Published private(set) var state = VoicePlayback()
    /// Called with the message id when a take plays to its end (not on stop):
    /// what the play-one-after-another chain hangs off.
    var onFinish: ((String) -> Void)?

    private var player: AVAudioPlayer?
    private var displayLink: CADisplayLink?

    var playingMsgId: String? { state.msgId }
    var rate: Float { state.rate }

    /// A tap on the play button: the message that is already on pauses and resumes,
    /// any other one takes the player over.
    func toggle(msgId: String, url: URL) {
        guard state.msgId == msgId, let p = player else {
            play(msgId: msgId, url: url)
            return
        }
        if p.isPlaying {
            p.pause()
            state.isPlaying = false
        } else {
            p.play()
            p.rate = state.rate
            state.isPlaying = true
        }
    }

    /// Starts a message, optionally from a point along it.
    func play(msgId: String, url: URL, from fraction: Double = 0) {
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.delegate = self
        p.enableRate = true
        p.prepareToPlay()
        p.currentTime = p.duration * max(0, min(1, fraction))
        p.play()
        // the rate only sticks once the player is running: set before play() it is lost
        // in prepareToPlay and every message comes out at x1
        p.rate = state.rate
        player = p
        state.msgId = msgId
        state.isPlaying = true
        state.progress = p.duration > 0 ? p.currentTime / p.duration : 0
        displayLink = CADisplayLink(target: self, selector: #selector(tick))
        displayLink?.add(to: .main, forMode: .common)
    }

    /// Moving inside the message that is playing. Another message is not touched: its
    /// own bubble starts it before asking for a position.
    func seek(msgId: String, to fraction: Double) {
        guard state.msgId == msgId, let p = player else { return }
        p.currentTime = p.duration * max(0, min(1, fraction))
        state.progress = p.duration > 0 ? p.currentTime / p.duration : 0
    }

    /// The speed is the player's, not the message's: it carries on to the next one.
    func cycleRate() {
        state.rate = state.rate == 1.0 ? 1.5 : state.rate == 1.5 ? 2.0 : 1.0
        player?.rate = state.rate
    }

    func stop() {
        player?.stop()
        player = nil
        displayLink?.invalidate()
        displayLink = nil
        state.msgId = nil
        state.isPlaying = false
        state.progress = 0
    }

    @objc private func tick() {
        guard let p = player, p.duration > 0 else { return }
        state.progress = p.currentTime / p.duration
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = state.msgId
        // the last displaylink tick lands short of the end: the transcript
        // highlight is told the take played out whole before the player lets go
        state.progress = 1
        stop()
        if flag, let finished { onFinish?(finished) }
    }
}

/// Waveform: bars filled in as playback progresses, a tap or drag seeks.
final class WaveformView: UIView {
    var amplitudes: [Int] = [] {
        didSet { setNeedsDisplay() }
    }
    /// The player reports its position every frame and every bubble hears it, so a
    /// position that has not moved redraws nothing.
    var progress: Double = 0 {
        didSet {
            guard progress != oldValue else { return }
            // the position is spoken as a percentage, the way a slider's is
            accessibilityValue = "\(Int((progress * 100).rounded()))"
            setNeedsDisplay()
        }
    }
    var playedColor = UIColor(Theme.accent)
    var unplayedColor = UIColor.systemGray3
    var onSeek: ((Double) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityIdentifier = "voice.wave"
        accessibilityTraits = .adjustable
        accessibilityLabel = String(localized: "Position")
        accessibilityValue = "0"
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

    override func accessibilityIncrement() { onSeek?(min(1, progress + 0.1)) }

    override func accessibilityDecrement() { onSeek?(max(0, progress - 0.1)) }

    /// Only a movement along the wave seeks. A drag that goes up or down over a voice
    /// bubble is the reader scrolling the feed, and the wave lets it through.
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let pan = g as? UIPanGestureRecognizer else { return true }
        let v = pan.velocity(in: self)
        return abs(v.x) > abs(v.y)
    }

    override func draw(_ rect: CGRect) {
        guard !amplitudes.isEmpty, let ctx = UIGraphicsGetCurrentContext() else { return }
        let barW: CGFloat = 2.5
        let gap: CGFloat = 1.5
        let count = min(amplitudes.count, Int(bounds.width / (barW + gap)))
        guard count > 0 else { return }
        let step = CGFloat(amplitudes.count) / CGFloat(count)
        let midY = bounds.midY
        for i in 0..<count {
            let amp = amplitudes[Int(CGFloat(i) * step)]
            let h = max(barW, CGFloat(amp) / 31 * bounds.height)
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
    private let rateButton = UIButton(type: .system)
    private let transcriptButton = UIButton(type: .system)
    private let transcriptSpinner = UIActivityIndicatorView(style: .medium)
    private var msg: Message?
    private var playback = VoicePlayback()
    private var playIcon = "play.circle.fill"
    private var cancellables: Set<AnyCancellable> = []
    var onTranscript: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        playButton.setImage(UIImage(systemName: "play.circle.fill"), for: .normal)
        playButton.tintColor = UIColor(Theme.accent)
        playButton.accessibilityIdentifier = "voice.play"
        playButton.addTarget(self, action: #selector(togglePlay), for: .touchUpInside)
        durationLabel.textColor = .secondaryLabel
        fileIcon.tintColor = UIColor(Theme.accent)
        rateButton.accessibilityIdentifier = "voice.rate"
        rateButton.addTarget(self, action: #selector(cycleRate), for: .touchUpInside)
        rateButton.layer.cornerRadius = 8
        rateButton.isHidden = true
        transcriptButton.setImage(UIImage(systemName: "textformat",
                                          withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)),
                                  for: .normal)
        transcriptButton.accessibilityIdentifier = "voice.transcript"
        transcriptButton.accessibilityLabel = String(localized: "Transcript")
        transcriptButton.addTarget(self, action: #selector(tapTranscript), for: .touchUpInside)
        transcriptButton.layer.cornerRadius = 8
        transcriptButton.layer.borderWidth = 1
        transcriptSpinner.hidesWhenStopped = true
        addSubview(playButton)
        addSubview(waveform)
        addSubview(durationLabel)
        addSubview(rateButton)
        addSubview(transcriptButton)
        addSubview(transcriptSpinner)
        addSubview(fileIcon)
        addSubview(fileName)
        waveform.onSeek = { [weak self] fraction in
            self?.seek(to: fraction)
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleFileTap))
        tap.delegate = self
        addGestureRecognizer(tap)

        // the plate follows the player rather than polling it: the position of a
        // message playing in another chat is right the moment this one is reused
        VoicePlayer.shared.$state
            .sink { [weak self] state in self?.apply(state) }
            .store(in: &cancellables)

        // the spinner follows recognition wherever it was started, so a cell
        // reused mid-work still shows it; the availability probe answers
        // asynchronously and unhides the button when it lands. @Published
        // emits on willSet, so the sinks must use the emitted value — reading
        // the shared property here would see the state from before the change
        TranscriptWork.shared.$inFlight
            .sink { [weak self] ids in
                self?.applyTranscriptWork(inFlight: ids, available: TranscriptWork.shared.available)
            }
            .store(in: &cancellables)
        TranscriptWork.shared.$available
            .sink { [weak self] avail in
                self?.applyTranscriptWork(inFlight: TranscriptWork.shared.inFlight, available: avail)
            }
            .store(in: &cancellables)
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
        rateButton.tintColor = tint
        rateButton.titleLabel?.font = Theme.Text.voiceDuration.uiFont
        rateButton.layer.borderColor = tint.withAlphaComponent(0.5).cgColor
        rateButton.layer.borderWidth = 1
        fileName.textColor = outgoing ? UIColor(Theme.outgoingText) : .label
        durationLabel.textColor = outgoing ? UIColor(Theme.outgoingMeta) : .secondaryLabel
        waveform.playedColor = tint
        waveform.unplayedColor = outgoing
            ? UIColor(Theme.outgoingMeta).withAlphaComponent(0.5) : .systemGray3
        let isVoice = msg.kind == .voice
        playButton.isHidden = !isVoice
        waveform.isHidden = !isVoice
        rateButton.isHidden = true
        fileIcon.isHidden = isVoice
        fileName.isHidden = isVoice
        transcriptButton.tintColor = tint
        transcriptButton.layer.borderColor = tint.withAlphaComponent(0.5).cgColor
        // the unfolded state reads as a pressed button
        transcriptButton.backgroundColor = msg.transcriptShown ? tint.withAlphaComponent(0.25) : .clear
        transcriptSpinner.color = tint
        if isVoice { TranscriptWork.shared.probeIfNeeded() }
        applyTranscriptWork(inFlight: TranscriptWork.shared.inFlight,
                            available: TranscriptWork.shared.available)
        if isVoice {
            waveform.amplitudes = msg.media?.waveform ?? []
            let raw = msg.media?.dur ?? 0
            if raw < 1 {
                // a sub-second voice message shows tenths: "0:00,5"
                durationLabel.text = String(format: "0:00,%01d", Int(raw * 10))
            } else {
                // rounded to the nearest second: 2.7s reads «0:03», not «0:02»
                let dur = Int(raw.rounded())
                durationLabel.text = String(format: "%d:%02d", dur / 60, dur % 60)
            }
            accessibilityLabel = String(localized: "Voice message, \(durationLabel.text ?? "")")
            apply(VoicePlayer.shared.state)
        } else {
            fileName.text = msg.media?.name ?? String(localized: "File")
            let size = msg.media?.size ?? 0
            durationLabel.text = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
    }

    /// The player moved: only the plate of the message it is on shows a position, a
    /// pause icon and the speed; every other plate stands at the start.
    private func apply(_ state: VoicePlayback) {
        playback = state
        guard let msg, msg.kind == .voice else { return }
        let mine = state.msgId == msg.id
        let running = mine && state.isPlaying
        let icon = running ? "pause.circle.fill" : "play.circle.fill"
        if icon != playIcon {
            playIcon = icon
            playButton.setImage(UIImage(systemName: icon), for: .normal)
            playButton.accessibilityLabel = running ? String(localized: "Pause") : String(localized: "Play")
            // the label is what a reader hears and is translated with the rest of the
            // interface; which of the two states the button is in is told by the
            // identifier, so a run does not depend on the language of the host
            playButton.accessibilityIdentifier = running ? "voice.pause" : "voice.play"
        }
        waveform.progress = mine ? state.progress : 0
        rateButton.isHidden = !mine
        let title = Self.rateTitle(state.rate)
        if rateButton.title(for: .normal) != title {
            rateButton.setTitle(title, for: .normal)
            rateButton.accessibilityLabel = String(localized: "Speed \(title)")
            // the label is translated; the speed itself is carried as the value, which
            // is the same in every language
            rateButton.accessibilityValue = title
        }
    }

    /// «1×», «1,5×», «2×» — the comma is the decimal separator everywhere else on screen.
    static func rateTitle(_ rate: Float) -> String {
        rate == 1.5 ? "1,5×" : String(format: "%g×", rate)
    }

    @objc private func cycleRate() {
        Haptics.light()
        VoicePlayer.shared.cycleRate()
    }

    @objc private func tapTranscript() {
        Haptics.light()
        onTranscript?()
    }

    /// The button shows only where a tap can do something: a cached transcript
    /// always folds and unfolds, a fresh take needs recognition available on
    /// this device. While recognition runs the button gives way to a spinner.
    private func applyTranscriptWork(inFlight: Set<String>, available: Bool?) {
        guard let msg, msg.kind == .voice else {
            transcriptButton.isHidden = true
            transcriptSpinner.stopAnimating()
            return
        }
        let working = inFlight.contains(msg.id)
        let usable = !(msg.transcript ?? "").isEmpty || available == true
        transcriptButton.isHidden = working || !usable
        if working { transcriptSpinner.startAnimating() } else { transcriptSpinner.stopAnimating() }
        setNeedsLayout()
    }

    /// A tap on the wave of the message that is playing moves inside it; on any other
    /// message it starts that one from the point touched.
    private func seek(to fraction: Double) {
        guard let msg, msg.kind == .voice else { return }
        if playback.msgId == msg.id {
            VoicePlayer.shared.seek(msgId: msg.id, to: fraction)
            return
        }
        withPlayableFile { url in
            VoicePlayer.shared.play(msgId: msg.id, url: url, from: fraction)
        }
    }

    @objc private func togglePlay() {
        guard let msg else { return }
        Haptics.light()
        withPlayableFile { url in
            VoicePlayer.shared.toggle(msgId: msg.id, url: url)
        }
    }

    /// The decrypted file under a name AVAudioPlayer will take: it identifies the
    /// container by the extension and refuses a bare media id.
    private func withPlayableFile(_ body: @escaping (URL) -> Void) {
        guard let media = msg?.media else { return }
        Task {
            guard let mm = AppState.shared.media,
                  let url = try? await mm.fetch(media) else { return }
            let linked = url.deletingPathExtension().appendingPathExtension("m4a")
            if !FileManager.default.fileExists(atPath: linked.path) {
                try? FileManager.default.copyItem(at: url, to: linked)
            }
            await MainActor.run { body(linked) }
        }
    }

    // one row: play button on the left, waveform on the right, the duration small beneath
    // it; BubbleLayout puts the message time in the bottom right on the duration's line,
    // and the speed sits in the gap between the two. Everything is placed from the
    // plate's height, which follows the text size, so a large setting keeps the wave
    // and the label together instead of leaving the label in empty space
    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height
        let button = min(40, h - 2)
        playButton.frame = CGRect(x: 0, y: (h - button) / 2, width: button, height: button)
        let left = button + 8
        let labelH = ceil(durationLabel.font.lineHeight)
        let waveH = h - labelH - 5
        // the transcript button (or its spinner) takes the right edge of the
        // wave's row; with neither shown the wave gets the row whole
        let tSide: CGFloat = 24
        let reserve: CGFloat = (transcriptButton.isHidden && !transcriptSpinner.isAnimating) ? 0 : tSide + 6
        waveform.frame = CGRect(x: left, y: 2, width: bounds.width - left - reserve, height: waveH)
        transcriptButton.frame = CGRect(x: bounds.width - tSide, y: 2 + (waveH - tSide) / 2,
                                        width: tSide, height: tSide)
        transcriptSpinner.center = CGPoint(x: transcriptButton.frame.midX, y: transcriptButton.frame.midY)
        // the voice duration is measured so the speed can sit right next to it; a file
        // puts its size in the same label and has the row to itself
        let durationWidth = msg?.kind == .voice
            ? min(bounds.width - left - 50, ceil(durationLabel.sizeThatFits(bounds.size).width))
            : bounds.width - left
        durationLabel.frame = CGRect(x: left, y: h - labelH - 1, width: durationWidth, height: labelH)
        let rateH = labelH + 4
        rateButton.frame = CGRect(x: durationLabel.frame.maxX + 8, y: h - rateH + 1,
                                  width: ceil(rateH * 2.1), height: rateH)
        let icon = min(32, h - 10)
        fileIcon.frame = CGRect(x: (button - icon) / 2, y: (h - labelH - 4 - icon) / 2 + 2,
                                width: icon, height: icon)
        fileName.frame = CGRect(x: left, y: 2, width: bounds.width - left, height: waveH)
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
