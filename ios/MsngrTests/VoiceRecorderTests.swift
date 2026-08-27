import AVFoundation
import XCTest
@testable import Msngr

/// The 0.3 s cut: a touch of the microphone shorter than that is an accident, and it
/// leaves neither a message nor a file. The takes are recorded for real, which needs the
/// microphone; the simulator grants it per device (`xcrun simctl privacy <udid> grant
/// microphone msngr.msngr`), and without it there is nothing to measure, so those
/// tests step aside instead of passing quietly.
@MainActor
final class VoiceRecorderTests: XCTestCase {
    func testTheCutSitsBelowAQuickWord() {
        XCTAssertTrue(VoiceRecorder.isAccidental(0.29))
        XCTAssertFalse(VoiceRecorder.isAccidental(0.3))
        XCTAssertFalse(VoiceRecorder.isAccidental(0.5))
    }

    /// The shortest take this machine can make: whatever it turns out to be, the recorder
    /// hands back nothing under the cut, and what it drops it deletes.
    func testTheShortestTakeIsDroppedOrIsOverTheCut() throws {
        let recorder = try startedRecorder()
        let url = try XCTUnwrap(recorder.fileURL)
        let take = recorder.stop()
        if let take {
            XCTAssertFalse(VoiceRecorder.isAccidental(take.duration),
                           "a take of \(take.duration) s came back as a message")
            try? FileManager.default.removeItem(at: take.url)
        } else {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                           "the dropped take left its file behind")
        }
    }

    /// Over the cut it is a message like any other: a file and a waveform of 100 buckets.
    func testTakeOverTheCutBecomesAMessage() throws {
        let recorder = try startedRecorder()
        Thread.sleep(forTimeInterval: 0.6)
        let take = try XCTUnwrap(recorder.stop(), "a take over 0.3 s was dropped")
        XCTAssertGreaterThanOrEqual(take.duration, VoiceRecorder.minimumTake)
        XCTAssertTrue(FileManager.default.fileExists(atPath: take.url.path))
        XCTAssertEqual(take.waveform.count, 100)
        try? FileManager.default.removeItem(at: take.url)
    }

    /// Cancelling takes the file with it whatever the take was worth.
    func testCancelRemovesTheFile() throws {
        let recorder = try startedRecorder()
        let url = try XCTUnwrap(recorder.fileURL)
        Thread.sleep(forTimeInterval: 0.4)
        recorder.cancel()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "a cancelled take left its file behind")
    }

    private func startedRecorder() throws -> VoiceRecorder {
        try XCTSkipUnless(MicGate.current == .granted,
                          "the microphone is not granted on this simulator")
        let recorder = VoiceRecorder()
        try recorder.start()
        return recorder
    }
}
