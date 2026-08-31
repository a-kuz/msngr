import XCTest
import MsngrCore
@testable import Msngr

/// The pre-media sounds of a call: the ringback while dialing, the ringtone
/// while ringing, silence everywhere else.
final class CallSoundsTests: XCTestCase {
    override func tearDown() {
        CallSounds.shared.apply(.idle)
        super.tearDown()
    }

    func testDialingLoopsTheRingback() {
        CallSounds.shared.apply(.dialing)
        XCTAssertEqual(CallSounds.shared.current, "call-dial")
    }

    func testRingingLoopsTheRingtone() {
        CallSounds.shared.apply(.ringing)
        XCTAssertEqual(CallSounds.shared.current, "call-ring")
    }

    func testMediaTakingOverStopsTheSound() {
        CallSounds.shared.apply(.dialing)
        CallSounds.shared.apply(.connecting)
        XCTAssertNil(CallSounds.shared.current)
    }

    func testEndedStopsTheSound() {
        CallSounds.shared.apply(.ringing)
        CallSounds.shared.apply(.ended(.hangup))
        XCTAssertNil(CallSounds.shared.current)
    }

    /// The same phase repeated must not restart the loop from its beginning.
    func testRepeatedPhaseKeepsTheLoop() {
        CallSounds.shared.apply(.dialing)
        CallSounds.shared.apply(.dialing)
        XCTAssertEqual(CallSounds.shared.current, "call-dial")
    }
}
