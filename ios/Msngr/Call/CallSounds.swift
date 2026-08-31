import AVFoundation
import MsngrCore

/// The sounds a call makes before media flows: the ringback for the caller
/// while it dials, the ringtone for the callee while it rings. Media taking
/// over or the call ending stops them. Playback is ambient, so the silent
/// switch silences both; the media path's own audio session (WebRTC's) is
/// configured by the transport and is not touched here.
final class CallSounds {
    static let shared = CallSounds()

    private var player: AVAudioPlayer?
    /// the sound currently looping, by resource name; nil when silent
    private(set) var current: String?

    func apply(_ phase: CallPhase) {
        switch phase {
        case .dialing: play("call-dial")
        case .ringing: play("call-ring")
        case .idle, .connecting, .active, .ended: stop()
        }
    }

    private func play(_ name: String) {
        guard current != name else { return }
        stop()
        guard let url = Bundle.main.url(forResource: name, withExtension: "caf") else { return }
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.numberOfLoops = -1
        player?.play()
        current = name
    }

    private func stop() {
        player?.stop()
        player = nil
        current = nil
    }
}
