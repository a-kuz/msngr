import XCTest
@testable import Msngr

/// The microphone rule: recording starts only once permission is granted, so no
/// take is ever captured underneath the system dialog.
final class MicGateTests: XCTestCase {
    func testUndeterminedAsksInsteadOfRecording() {
        XCTAssertEqual(MicGate.decide(.undetermined), .ask)
    }

    func testDeniedExplainsInsteadOfRecording() {
        XCTAssertEqual(MicGate.decide(.denied), .explain)
    }

    func testGrantedRecords() {
        XCTAssertEqual(MicGate.decide(.granted), .record)
    }
}
