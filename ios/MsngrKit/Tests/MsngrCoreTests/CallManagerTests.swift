import XCTest
@testable import MsngrCore

/// A media transport that answers instantly and records what it was told.
final class FakeTransport: CallMediaTransport, @unchecked Sendable {
    let lock = NSLock()
    var added: [CallSignal.IceCandidate] = []
    var muted: Bool?
    var closed = false
    var remoteOffer: String?
    var remoteAnswer: String?
    private var continuation: AsyncStream<CallTransportEvent>.Continuation?
    private let stream: AsyncStream<CallTransportEvent>

    init() {
        var c: AsyncStream<CallTransportEvent>.Continuation!
        stream = AsyncStream { c = $0 }
        continuation = c
    }

    func makeOffer() async throws -> String { "offer-sdp" }
    func acceptAnswer(_ sdp: String) async throws {
        lock.lock(); remoteAnswer = sdp; lock.unlock()
    }
    func answerOffer(_ sdp: String) async throws -> String {
        lock.lock(); remoteOffer = sdp; lock.unlock()
        return "answer-sdp"
    }
    func add(candidates: [CallSignal.IceCandidate]) async {
        lock.lock(); added.append(contentsOf: candidates); lock.unlock()
    }
    func setMuted(_ muted: Bool) async {
        lock.lock(); self.muted = muted; lock.unlock()
    }
    func close() async {
        lock.lock(); closed = true; lock.unlock()
        continuation?.finish()
    }
    func events() -> AsyncStream<CallTransportEvent> { stream }
    func emit(_ event: CallTransportEvent) { continuation?.yield(event) }
}

/// Collects the signals a manager sends, in order.
final class SignalLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(CallSignal, String)] = []
    func record(_ signal: CallSignal, chatId: String) {
        lock.lock(); items.append((signal, chatId)); lock.unlock()
    }
    var all: [(CallSignal, String)] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
    var types: [CallSignal.SignalType] { all.map(\.0.type) }
}

final class CallManagerTests: XCTestCase {
    func makeManager(dialTimeout: TimeInterval = 60)
        -> (CallManager, SignalLog, FakeTransport) {
        let log = SignalLog()
        let transport = FakeTransport()
        let manager = CallManager(
            ownUserId: "me",
            sendSignal: { log.record($0, chatId: $1) },
            makeTransport: { transport },
            dialTimeout: dialTimeout)
        return (manager, log, transport)
    }

    func event(_ signal: CallSignal, chatId: String = "chat1", from: String = "peer",
               device: String = "d1", sentAt: Double = Date().timeIntervalSince1970) -> CallSignalEvent {
        CallSignalEvent(chatId: chatId, fromUserId: from, fromDeviceId: device,
                        sentAt: sentAt, signal: signal)
    }

    func testOutgoingCallReachesActive() async {
        let (manager, log, transport) = makeManager()
        await manager.startCall(chatId: "chat1", peerUserId: "peer")
        var state = await manager.current
        XCTAssertEqual(state.phase, .dialing)
        XCTAssertEqual(log.types, [.offer])
        XCTAssertEqual(log.all[0].0.sdp, "offer-sdp")

        await manager.handle(event(CallSignal(type: .answer, callId: log.all[0].0.callId, sdp: "their-answer")))
        state = await manager.current
        XCTAssertEqual(state.phase, .connecting)
        XCTAssertEqual(transport.remoteAnswer, "their-answer")

        transport.emit(.connected)
        try? await Task.sleep(nanoseconds: 100_000_000)
        state = await manager.current
        XCTAssertEqual(state.phase, .active)
        XCTAssertNotNil(state.connectedAt)
    }

    func testIncomingCallAcceptSendsAnswer() async {
        let (manager, log, transport) = makeManager()
        await manager.handle(event(CallSignal(type: .offer, callId: "c1", sdp: "their-offer")))
        var state = await manager.current
        XCTAssertEqual(state.phase, .ringing)
        XCTAssertEqual(state.peerUserId, "peer")

        await manager.accept()
        state = await manager.current
        XCTAssertEqual(state.phase, .connecting)
        XCTAssertEqual(transport.remoteOffer, "their-offer")
        XCTAssertEqual(log.types, [.answer])
        XCTAssertEqual(log.all[0].0.sdp, "answer-sdp")
    }

    func testDeclineSendsEndAndShowsIt() async {
        let (manager, log, transport) = makeManager()
        await manager.handle(event(CallSignal(type: .offer, callId: "c1", sdp: "s")))
        await manager.decline()
        let state = await manager.current
        XCTAssertEqual(state.phase, .ended(.decline))
        XCTAssertEqual(log.types, [.end])
        XCTAssertEqual(log.all[0].0.reason, .decline)
        XCTAssertFalse(transport.closed) // never opened
        await manager.reset()
        let idle = await manager.current
        XCTAssertEqual(idle.phase, .idle)
    }

    func testSecondOfferAnsweredBusy() async {
        let (manager, log, _) = makeManager()
        await manager.handle(event(CallSignal(type: .offer, callId: "c1", sdp: "s")))
        await manager.handle(event(CallSignal(type: .offer, callId: "c2", sdp: "s2"),
                                   chatId: "chat2", from: "other"))
        let state = await manager.current
        XCTAssertEqual(state.phase, .ringing)
        XCTAssertEqual(state.callId, "c1")
        XCTAssertEqual(log.types, [.end])
        XCTAssertEqual(log.all[0].0.callId, "c2")
        XCTAssertEqual(log.all[0].0.reason, .busy)
        XCTAssertEqual(log.all[0].1, "chat2")
    }

    func testPeerEndTearsDownAndClosesTransport() async {
        let (manager, log, transport) = makeManager()
        await manager.startCall(chatId: "chat1", peerUserId: "peer")
        let callId = log.all[0].0.callId
        await manager.handle(event(CallSignal(type: .end, callId: callId, reason: .decline)))
        let state = await manager.current
        XCTAssertEqual(state.phase, .ended(.decline))
        XCTAssertTrue(transport.closed)
    }

    func testForeignCallIdSignalsIgnored() async {
        let (manager, log, transport) = makeManager()
        await manager.startCall(chatId: "chat1", peerUserId: "peer")
        await manager.handle(event(CallSignal(type: .end, callId: "someone-else", reason: .hangup)))
        await manager.handle(event(CallSignal(type: .answer, callId: "someone-else", sdp: "x")))
        let state = await manager.current
        XCTAssertEqual(state.phase, .dialing)
        XCTAssertNil(transport.remoteAnswer)
        XCTAssertEqual(log.types, [.offer])
    }

    func testIceHeldUntilAcceptThenApplied() async {
        let (manager, _, transport) = makeManager()
        await manager.handle(event(CallSignal(type: .offer, callId: "c1", sdp: "s")))
        let held = CallSignal.IceCandidate(sdpMid: "0", sdpMLineIndex: 0, candidate: "cand-early")
        await manager.handle(event(CallSignal(type: .ice, callId: "c1", candidates: [held])))
        XCTAssertTrue(transport.added.isEmpty)

        await manager.accept()
        XCTAssertEqual(transport.added, [held])

        let late = CallSignal.IceCandidate(sdpMid: "0", sdpMLineIndex: 0, candidate: "cand-late")
        await manager.handle(event(CallSignal(type: .ice, callId: "c1", candidates: [late])))
        XCTAssertEqual(transport.added, [held, late])
    }

    func testLocalCandidatesBatchedIntoOneFrame() async {
        let (manager, log, transport) = makeManager()
        await manager.startCall(chatId: "chat1", peerUserId: "peer")
        transport.emit(.candidates([.init(sdpMid: "0", sdpMLineIndex: 0, candidate: "a")]))
        transport.emit(.candidates([.init(sdpMid: "0", sdpMLineIndex: 0, candidate: "b")]))
        try? await Task.sleep(nanoseconds: 400_000_000)
        let ice = log.all.filter { $0.0.type == .ice }
        XCTAssertEqual(ice.count, 1)
        XCTAssertEqual(ice[0].0.candidates?.map(\.candidate), ["a", "b"])
    }

    func testDialTimeoutEndsTheCall() async {
        let (manager, log, transport) = makeManager(dialTimeout: 0.2)
        await manager.startCall(chatId: "chat1", peerUserId: "peer")
        try? await Task.sleep(nanoseconds: 500_000_000)
        let state = await manager.current
        XCTAssertEqual(state.phase, .ended(.timeout))
        XCTAssertEqual(log.types, [.offer, .end])
        XCTAssertEqual(log.all[1].0.reason, .timeout)
        XCTAssertTrue(transport.closed)
    }

    func testGlareSmallerCallIdSurvives() async {
        // our call id sorts first: the incoming offer is ignored, we stay dialing
        let log = SignalLog()
        let manager = CallManager(
            ownUserId: "me",
            sendSignal: { log.record($0, chatId: $1) },
            makeTransport: { FakeTransport() },
            dialTimeout: 60)
        await manager.startCall(chatId: "chat1", peerUserId: "peer")
        let myCallId = log.all[0].0.callId
        await manager.handle(event(CallSignal(type: .offer, callId: "\u{FFFD}zzz", sdp: "s")))
        let state = await manager.current
        XCTAssertEqual(state.phase, .dialing)
        XCTAssertEqual(state.callId, myCallId)
        XCTAssertEqual(log.types, [.offer])
    }

    func testGlareLargerCallIdCancelsAndAnswers() async {
        let (manager, log, transport) = makeManager()
        await manager.startCall(chatId: "chat1", peerUserId: "peer")
        let myCallId = log.all[0].0.callId
        // an incoming call id that sorts before any UUID
        await manager.handle(event(CallSignal(type: .offer, callId: "!first", sdp: "their-offer")))
        let state = await manager.current
        XCTAssertEqual(state.phase, .connecting)
        XCTAssertEqual(state.callId, "!first")
        XCTAssertEqual(transport.remoteOffer, "their-offer")
        XCTAssertEqual(log.types, [.offer, .end, .answer])
        XCTAssertEqual(log.all[1].0.callId, myCallId)
        XCTAssertEqual(log.all[1].0.reason, .cancel)
    }

    func testAnswerFromOwnOtherDeviceStopsRinging() async {
        let (manager, log, _) = makeManager()
        await manager.handle(event(CallSignal(type: .offer, callId: "c1", sdp: "s")))
        await manager.handle(event(CallSignal(type: .answer, callId: "c1", sdp: "a"),
                                   from: "me", device: "other-device"))
        let state = await manager.current
        XCTAssertEqual(state.phase, .idle)
        XCTAssertTrue(log.all.isEmpty)
    }

    func testMutePassesThrough() async {
        let (manager, _, transport) = makeManager()
        await manager.startCall(chatId: "chat1", peerUserId: "peer")
        await manager.setMuted(true)
        let state = await manager.current
        XCTAssertTrue(state.muted)
        XCTAssertEqual(transport.muted, true)
    }
}
