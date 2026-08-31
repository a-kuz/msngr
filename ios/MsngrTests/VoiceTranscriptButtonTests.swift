import XCTest
@testable import Msngr
import MsngrCore

/// The transcript button follows TranscriptWork through its published streams.
/// @Published emits on willSet, so a subscriber must use the emitted value:
/// reading the shared property inside the sink sees the value from before the
/// change, which is how the button once stayed hidden after the availability
/// probe answered.
@MainActor
final class VoiceTranscriptButtonTests: XCTestCase {
    private func voiceMessage() -> Message {
        var m = Message(id: UUID().uuidString, chatId: "c", fromUserId: "me",
                        sentAt: 1_700_000_000, kind: .voice, text: nil,
                        status: .sent, isOutgoing: true)
        var media = MediaInfo(type: "voice", mediaId: "m1", key: "", hash: "",
                              size: 1, mime: "audio/mp4")
        media.dur = 5
        media.waveform = [1, 2, 3]
        m.media = media
        return m
    }

    private func button(in view: UIView) -> UIView? {
        view.subviews.first { $0.accessibilityIdentifier == "voice.transcript" }
    }

    private func spinner(in view: UIView) -> UIActivityIndicatorView? {
        view.subviews.compactMap { $0 as? UIActivityIndicatorView }.first
    }

    func testSpinnerFollowsTheEmittedInFlightSet() {
        let msg = voiceMessage()
        let view = VoiceMessageView(frame: CGRect(x: 0, y: 0, width: 220, height: 42))
        view.configure(msg: msg, outgoing: true)

        TranscriptWork.shared.begin(msg.id)
        XCTAssertEqual(spinner(in: view)?.isAnimating, true,
                       "recognition started: the spinner must run at once")
        XCTAssertEqual(button(in: view)?.isHidden, true)

        TranscriptWork.shared.end(msg.id)
        XCTAssertEqual(spinner(in: view)?.isAnimating, false,
                       "recognition ended: the spinner must stop at once")
    }
}
