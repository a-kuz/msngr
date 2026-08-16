import XCTest
@testable import Msngr

/// Правило микрофона: запись начинается только с разрешением. Раньше нажатие
/// начинало запись сразу, и первый дубль писался под системным диалогом.
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
