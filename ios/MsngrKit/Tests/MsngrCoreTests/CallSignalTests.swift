import XCTest
@testable import MsngrCore

final class CallSignalTests: XCTestCase {
    func testRoundTripThroughContentText() {
        let signal = CallSignal(
            type: .offer, callId: "c1",
            sdp: "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\n")
        let decoded = CallSignal.decode(signal.encoded)
        XCTAssertEqual(decoded, signal)
    }

    func testCandidatesRoundTrip() {
        let signal = CallSignal(
            type: .ice, callId: "c1",
            candidates: [
                .init(sdpMid: "0", sdpMLineIndex: 0, candidate: "candidate:1 1 udp 2122260223 10.0.0.2 50000 typ host"),
                .init(sdpMid: nil, sdpMLineIndex: 1, candidate: "candidate:2 1 udp 1686052607 1.2.3.4 50001 typ srflx"),
            ])
        let decoded = CallSignal.decode(signal.encoded)
        XCTAssertEqual(decoded, signal)
        XCTAssertEqual(decoded?.candidates?.count, 2)
    }

    func testEndReasonRoundTrip() {
        let signal = CallSignal(type: .end, callId: "c1", reason: .decline)
        XCTAssertEqual(CallSignal.decode(signal.encoded)?.reason, .decline)
    }

    func testDecodeRejectsForeignText() {
        XCTAssertNil(CallSignal.decode(nil))
        XCTAssertNil(CallSignal.decode("hello"))
        XCTAssertNil(CallSignal.decode("{\"type\":\"launch\"}"))
    }

    /// Only the offer has a freshness bar: a replayed offer must not ring, the
    /// other signal types are judged by the engine against the call's state.
    func testOfferGoesStaleAfterItsLifetime() {
        let now = Date().timeIntervalSince1970
        let offer = CallSignal(type: .offer, callId: "c1", sdp: "sdp")
        XCTAssertTrue(offer.isFresh(sentAt: now - 5, now: now))
        XCTAssertFalse(offer.isFresh(sentAt: now - CallSignal.offerLifetime - 1, now: now))
        let end = CallSignal(type: .end, callId: "c1", reason: .hangup)
        XCTAssertTrue(end.isFresh(sentAt: now - 3600, now: now))
    }

    /// Service on the wire and rowless in the feed: a call signal takes a seq
    /// but raises no unread count, no push and no message row.
    func testCallKindIsServiceAndRowless() {
        XCTAssertTrue(SyncEngine.serviceKinds.contains(CallSignal.kind))
        XCTAssertTrue(SyncEngine.rowlessKinds.contains(CallSignal.kind))
        XCTAssertFalse(SyncEngine.recordedServiceKinds.contains(CallSignal.kind))
    }
}
