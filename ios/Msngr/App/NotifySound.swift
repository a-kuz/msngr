import Foundation
import AVFoundation

/// The push sounds the app ships: caf files in the bundle, named to APNs by
/// file name. "default" is the system sound, "none" a banner with no sound at
/// all — the server then sends the push without a sound field, so the choice
/// holds whether the extension ran or not.
enum NotifySound: String, CaseIterable, Identifiable {
    case standard = "default"
    case chime1 = "chime1.caf"
    case chime2 = "chime2.caf"
    case chime3 = "chime3.caf"
    case silent = "none"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: String(localized: "Default")
        case .chime1: String(localized: "Chime")
        case .chime2: String(localized: "Bell")
        case .chime3: String(localized: "Triad")
        case .silent: String(localized: "Silent")
        }
    }

    /// Plays the sound once, so the picker answers the ear and not only the eye.
    private static var player: AVAudioPlayer?
    func preview() {
        guard self != .standard, self != .silent,
              let url = Bundle.main.url(forResource: (rawValue as NSString).deletingPathExtension,
                                        withExtension: "caf") else { return }
        Self.player = try? AVAudioPlayer(contentsOf: url)
        Self.player?.play()
    }
}
