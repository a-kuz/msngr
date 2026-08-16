import AVFoundation
import XCTest
@testable import Msngr

/// The 0.3 s cut: a touch of the microphone that lasted less than that is an accident,
/// and it leaves neither a message nor a file. Recording needs the microphone, which the
/// simulator grants per device (`xcrun simctl privacy <udid> grant microphone
/// ai.enface.Msngr`); without it there is nothing to measure and the tests step aside.
@MainActor
final class VoiceRecorderTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(MicGate.current == .granted,
                          "the microphone is not granted on this simulator")
    }

    func testShortTakeIsDroppedWithItsFile() throws {
        let recorder = VoiceRecorder()
        try recorder.start()
        let url = try XCTUnwrap(recorder.fileURL)
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertNil(recorder.stop(), "a take under 0.3 s came back as a message")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "the dropped take left its file behind")
    }

    /// Just over the threshold is a message like any other: a quick "ok" is not an accident.
    func testTakeOverTheThresholdBecomesAMessage() throws {
        let recorder = VoiceRecorder()
        try recorder.start()
        Thread.sleep(forTimeInterval: 0.6)
        let take = try XCTUnwrap(recorder.stop(), "a take over 0.3 s was dropped")
        XCTAssertGreaterThanOrEqual(take.duration, 0.3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: take.url.path))
        XCTAssertEqual(take.waveform.count, 100)
        try? FileManager.default.removeItem(at: take.url)
    }

    /// Cancelling takes the file with it whatever the take was worth.
    func testCancelRemovesTheFile() throws {
        let recorder = VoiceRecorder()
        try recorder.start()
        let url = try XCTUnwrap(recorder.fileURL)
        Thread.sleep(forTimeInterval: 0.4)
        recorder.cancel()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "a cancelled take left its file behind")
    }
}
