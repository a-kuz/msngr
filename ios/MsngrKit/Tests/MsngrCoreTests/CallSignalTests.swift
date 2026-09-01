import XCTest
@testable import MsngrCore

final class CallSignalTests: XCTestCase {
    /// The conference card: service on the wire with a row in the feed, and
    /// its text never reads as a call log or the other way round.
    func testLiveCallCardIsServiceWithARow() {
        XCTAssertTrue(SyncEngine.serviceKinds.contains(CallLive.kind))
        XCTAssertFalse(SyncEngine.rowlessKinds.contains(CallLive.kind))
        let card = CallLive(callId: "c1", startedAt: 100,
                            members: [.init(id: "a", name: "Alice")], endedAt: nil)
        XCTAssertEqual(CallLive.decode(card.encoded), card)
        XCTAssertNil(CallLog.decode(card.encoded))
        XCTAssertNil(CallLive.decode(CallLog(outcome: .missed, callId: "c1").encoded))
    }

    /// An incoming card lands as a `.call` row, the way a call log does, not
    /// as text.
    func testIncomingCardLandsAsACallRow() async throws {
        let db = try AppDatabase.openInMemory()
        var content = ContentPayload(kind: CallLive.kind)
        content.text = CallLive(callId: "c1", startedAt: 1, members: [.init(id: "peer", name: "Peer")]).encoded
        try await db.write { dbc in
            try SyncEngine.applyContent(dbc, content, chatId: "chat1", seq: 3, from: "peer",
                                        sentAt: 1, ts: 1, ownUserId: "me")
        }
        let row = try await db.read { dbc in
            try Message.fetchOne(dbc, key: Message.feedId(chatId: "chat1", seq: 3))
        }
        XCTAssertEqual(row?.kind, .call)
        XCTAssertEqual(row?.callLive?.callId, "c1")
    }

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

    func testCallLogRoundTrip() {
        let log = CallLog(outcome: .completed, duration: 42.5, callId: "c1")
        XCTAssertEqual(CallLog.decode(log.encoded), log)
        XCTAssertNil(CallLog.decode("group:{}"))
        XCTAssertNil(CallLog.decode(nil))
        var msg = Message(id: "m", chatId: "c", fromUserId: "u", sentAt: 0,
                          kind: .call, text: log.encoded, status: .sent, isOutgoing: true)
        XCTAssertEqual(msg.callLog, log)
        msg.text = "plain"
        XCTAssertNil(msg.callLog)
    }

    /// A call log is service on the wire — no unread, no push — but it does
    /// leave a feed row, the way a group event does.
    func testCallLogKindIsServiceWithARow() {
        XCTAssertTrue(SyncEngine.serviceKinds.contains(CallLog.kind))
        XCTAssertFalse(SyncEngine.rowlessKinds.contains(CallLog.kind))
    }
}
