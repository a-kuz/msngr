import UIKit
import AVFoundation
import Combine
import MsngrCore

/// What the circle draws: which round video has the sound right now, whether it
/// is running and how far it has got. One value so a subscriber sees a whole
/// state, the same shape VoicePlayback has.
struct RoundVideoPlayback: Equatable {
    var msgId: String?
    var isPlaying = false
    var progress: Double = 0
}

/// Global player for round video messages: one per app, owns the AVPlayer whose
/// sound is on. The feed's muted loops are the cells' own; this player exists
/// only from the tap that asks for sound until the clip ends or is stopped.
/// Several AVPlayerLayers may render it at once — the bubble and the docked
/// circle both point here.
final class RoundVideoPlayer: NSObject, ObservableObject {
    static let shared = RoundVideoPlayer()
    @Published private(set) var state = RoundVideoPlayback()

    private(set) var player: AVPlayer?
    private var displayLink: CADisplayLink?
    private var finishObserver: NSObjectProtocol?
    /// Called with the message id when a circle plays to its end (not on stop):
    /// what the play-one-after-another chain hangs off.
    var onFinish: ((String) -> Void)?

    /// A tap on the circle: the message that already has the sound pauses and
    /// resumes, any other one takes the player over and starts from the top.
    func toggle(msgId: String, url: URL) {
        guard state.msgId == msgId, let p = player else {
            play(msgId: msgId, url: url)
            return
        }
        if state.isPlaying {
            p.pause()
            state.isPlaying = false
        } else {
            p.play()
            state.isPlaying = true
        }
    }

    func play(msgId: String, url: URL) {
        stop()
        // claiming the audio session takes long enough to feel under a finger;
        // the player does not wait for it, and the first muted frames are the
        // same ones the loop was already showing
        Task.detached {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        let p = AVPlayer(url: url)
        // a local file needs no stall protection, and the tap must answer now
        p.automaticallyWaitsToMinimizeStalling = false
        finishObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: p.currentItem, queue: .main) { [weak self] _ in
            guard let self else { return }
            let finished = self.state.msgId
            self.stop()
            if let finished { self.onFinish?(finished) }
        }
        p.playImmediately(atRate: 1)
        player = p
        state = RoundVideoPlayback(msgId: msgId, isPlaying: true, progress: 0)
        displayLink = CADisplayLink(target: self, selector: #selector(tick))
        displayLink?.add(to: .main, forMode: .common)
    }

    func stop() {
        if let finishObserver { NotificationCenter.default.removeObserver(finishObserver) }
        finishObserver = nil
        player?.pause()
        player = nil
        displayLink?.invalidate()
        displayLink = nil
        state = RoundVideoPlayback()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// The state is @Published and every cell in the reuse pool hears it, so
    /// the position is spoken at 10 Hz, not per frame; the ring smooths the
    /// steps with its own short animation.
    private var lastTick: CFTimeInterval = 0

    @objc private func tick() {
        let now = CACurrentMediaTime()
        guard now - lastTick > 0.1 else { return }
        guard let p = player, let item = p.currentItem, item.duration.seconds > 0 else { return }
        lastTick = now
        state.progress = p.currentTime().seconds / item.duration.seconds
    }
}

/// The listened dots beside the time of a voice or round video. An incoming
/// note carries one filled accent dot until it is heard. An outgoing one shows
/// a dot that fills when somebody has listened, and in a small group a second
/// that fills when everyone has; a hollow dot is its not-yet state.
final class NoteDotsView: UIView {
    var dots: [Bool] = [] {
        didSet { if dots != oldValue { setNeedsDisplay() } }
    }
    var color: UIColor = .white {
        didSet { if color != oldValue { setNeedsDisplay() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard !dots.isEmpty, let ctx = UIGraphicsGetCurrentContext() else { return }
        let d: CGFloat = 5
        let gap: CGFloat = 2
        var x: CGFloat = 0
        for filled in dots {
            let r = CGRect(x: x, y: bounds.midY - d / 2, width: d, height: d)
            if filled {
                ctx.setFillColor(color.cgColor)
                ctx.fillEllipse(in: r)
            } else {
                ctx.setStrokeColor(color.withAlphaComponent(0.55).cgColor)
                ctx.setLineWidth(1)
                ctx.strokeEllipse(in: r.insetBy(dx: 0.5, dy: 0.5))
            }
            x += d + gap
        }
    }
}

/// The progress ring around a round video with the sound on: a hairline circle
/// stroked clockwise from twelve o'clock, drawn just inside the video's edge.
final class RoundProgressRing: UIView {
    private let track = CAShapeLayer()
    private let ring = CAShapeLayer()

    var progress: Double = 0 {
        didSet {
            guard progress != oldValue else { return }
            // the player reports at 10 Hz; a short linear animation turns the
            // steps back into a smooth sweep
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
            ring.strokeEnd = max(0, min(1, progress))
            CATransaction.commit()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for layer in [track, ring] {
            layer.fillColor = UIColor.clear.cgColor
            layer.lineWidth = 3
            layer.lineCap = .round
            self.layer.addSublayer(layer)
        }
        track.strokeColor = UIColor.white.withAlphaComponent(0.25).cgColor
        ring.strokeColor = UIColor.white.cgColor
        ring.strokeEnd = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset: CGFloat = 4
        let path = UIBezierPath(arcCenter: CGPoint(x: bounds.midX, y: bounds.midY),
                                radius: bounds.width / 2 - inset,
                                startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: true)
        track.path = path.cgPath
        ring.path = path.cgPath
        track.frame = bounds
        ring.frame = bounds
    }
}

/// The small circle a round video keeps playing in while the reader scrolls
/// away from its bubble. It renders the shared player through a layer of its
/// own; a tap brings the feed back to the message, the cross stops the sound.
final class RoundVideoDockView: UIView {
    static let side: CGFloat = 84
    private let videoLayer = AVPlayerLayer()
    private let ringView = RoundProgressRing()
    private let closeButton = UIButton(type: .system)
    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 3)

        videoLayer.videoGravity = .resizeAspectFill
        videoLayer.masksToBounds = true
        layer.addSublayer(videoLayer)
        addSubview(ringView)

        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "xmark.circle.fill",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 20))
        closeButton.configuration = config
        closeButton.tintColor = .white
        closeButton.accessibilityIdentifier = "chat.roundVideoDock.close"
        closeButton.accessibilityLabel = String(localized: "Stop")
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        addSubview(closeButton)

        isAccessibilityElement = false
        accessibilityIdentifier = "chat.roundVideoDock"
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError() }

    func attach(_ player: AVPlayer?) {
        videoLayer.player = player
    }

    func setProgress(_ p: Double) { ringView.progress = p }

    @objc private func tapped() { onTap?() }

    @objc private func closeTapped() { RoundVideoPlayer.shared.stop() }

    override func layoutSubviews() {
        super.layoutSubviews()
        videoLayer.frame = bounds
        videoLayer.cornerRadius = bounds.width / 2
        ringView.frame = bounds
        let side: CGFloat = 30
        closeButton.frame = CGRect(x: bounds.maxX - side + 4, y: -4, width: side, height: side)
    }

    /// The cross overhangs the circle; touches on it still count.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event) || closeButton.frame.contains(point)
    }
}
