import XCTest
@testable import Msngr

/// The rules of the microphone gesture: an accidental touch leaves nothing behind, a
/// cancelled take is not restarted by the same finger, and a take that loses the screen
/// is dropped rather than sent.
final class RecordingGestureTests: XCTestCase {
    func testTouchAsksBeforeRecording() {
        var g = RecordingGesture()
        XCTAssertEqual(g.touchDown(), .ask)
        XCTAssertEqual(g.permitted(true), .start)
    }

    func testSecondTouchDoesNotAskTwice() {
        var g = RecordingGesture()
        _ = g.touchDown()
        XCTAssertEqual(g.touchDown(), .none)
    }

    /// The tap ends while the microphone request is still in flight: nothing may start
    /// afterwards, or a recording runs on with nobody holding it.
    func testTapEndingBeforePermissionStartsNothing() {
        var g = RecordingGesture()
        _ = g.touchDown()
        XCTAssertEqual(g.touchUp(), .none)
        XCTAssertEqual(g.permitted(true), .none)
        XCTAssertEqual(g.phase, .idle)
    }

    func testRefusedPermissionLeavesNoTake() {
        var g = RecordingGesture()
        _ = g.touchDown()
        XCTAssertEqual(g.permitted(false), .none)
        XCTAssertEqual(g.phase, .idle)
    }

    func testHoldAndReleaseFinishes() {
        var g = RecordingGesture()
        _ = g.touchDown()
        _ = g.permitted(true)
        XCTAssertEqual(g.moved(CGSize(width: -20, height: -10)), .none)
        XCTAssertEqual(g.touchUp(), .finish)
    }

    func testSlideLeftCancels() {
        var g = RecordingGesture()
        _ = g.touchDown()
        _ = g.permitted(true)
        XCTAssertEqual(g.moved(CGSize(width: -150, height: 0)), .cancel)
    }

    /// The finger goes on moving over the button after the cancel: no second take
    /// starts, and letting go sends nothing.
    func testFingerAfterCancelStartsNothing() {
        var g = RecordingGesture()
        _ = g.touchDown()
        _ = g.permitted(true)
        _ = g.moved(CGSize(width: -150, height: 0))
        XCTAssertEqual(g.moved(CGSize(width: -160, height: -80)), .none)
        XCTAssertEqual(g.moved(CGSize(width: -20, height: 0)), .none)
        XCTAssertEqual(g.touchUp(), .none)
    }

    func testSlideUpLocksAndSurvivesTheFinger() {
        var g = RecordingGesture()
        _ = g.touchDown()
        _ = g.permitted(true)
        XCTAssertEqual(g.moved(CGSize(width: 0, height: -80)), .lock)
        XCTAssertEqual(g.touchUp(), .none)
        XCTAssertTrue(g.isLocked)
        XCTAssertEqual(g.send(), .finish)
        XCTAssertFalse(g.isLocked)
    }

    func testLockedTakeIsDiscardedByItsButton() {
        var g = RecordingGesture()
        _ = g.touchDown()
        _ = g.permitted(true)
        _ = g.moved(CGSize(width: 0, height: -80))
        XCTAssertEqual(g.discard(), .cancel)
        XCTAssertEqual(g.phase, .idle)
    }

    /// Leaving the screen, leaving the app or a call: whatever was said is dropped, not
    /// sent as a stump.
    func testInterruptionDropsARunningTake() {
        var g = RecordingGesture()
        _ = g.touchDown()
        _ = g.permitted(true)
        XCTAssertEqual(g.interrupted(), .cancel)
        XCTAssertEqual(g.phase, .idle)
    }

    func testInterruptionDropsALockedTake() {
        var g = RecordingGesture()
        _ = g.touchDown()
        _ = g.permitted(true)
        _ = g.moved(CGSize(width: 0, height: -80))
        XCTAssertEqual(g.interrupted(), .cancel)
    }

    func testInterruptionWithoutATakeCancelsNothing() {
        var g = RecordingGesture()
        XCTAssertEqual(g.interrupted(), .none)
        _ = g.touchDown()
        XCTAssertEqual(g.interrupted(), .none)
    }

    /// One click at the start of a take does not flatten the speech after it:
    /// the scale is set by the bulk of the buckets, and the spike is clipped.
    func testWaveformScaleIgnoresASingleSpike() {
        var levels = [Float](repeating: 0.1, count: 99)
        levels[0] = 1.0
        let wave = VoiceRecorder.normalize(levels)
        XCTAssertEqual(wave[0], 31)
        XCTAssertEqual(wave[50], 31, "the speech itself is drawn at full height")
        XCTAssertEqual(VoiceRecorder.normalize([0, 0.0025, 0.01]), [0, 16, 31],
                       "the square root lifts the quiet buckets")
        XCTAssertEqual(VoiceRecorder.normalize([]), [])
    }

    func testRateTitles() {
        XCTAssertEqual(VoiceMessageView.rateTitle(1), "1×")
        XCTAssertEqual(VoiceMessageView.rateTitle(1.5), "1,5×")
        XCTAssertEqual(VoiceMessageView.rateTitle(2), "2×")
    }
}
