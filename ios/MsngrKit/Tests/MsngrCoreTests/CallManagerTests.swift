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

    var restarted = false
    var videoEnabled: Bool?
    func makeOffer() async throws -> String { "offer-sdp" }
    func setVideo(enabled: Bool) async {
        lock.lock(); videoEnabled = enabled; lock.unlock()
    }
    func restartOffer() async throws -> String {
        lock.lock(); restarted = true; lock.unlock()
        return "restart-sdp"
    }
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
    var held: Bool?
    func setHeld(_ held: Bool) async {
        lock.lock(); self.held = held; lock.unlock()
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

/// Collects plain strings from a callback, in order.
final class SignalLogStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func record(_ s: String) {
        lock.lock(); items.append(s); lock.unlock()
    }
    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}

/// Collects the call logs a manager publishes.
final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(CallLog, String)] = []
    func record(_ log: CallLog, chatId: String) {
        lock.lock(); items.append((log, chatId)); lock.unlock()
    }
    var all: [(CallLog, String)] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}

final class CallManagerTests: XCTestCase {
    func makeManager(dialTimeout: TimeInterval = 60)
        -> (CallManager, SignalLog, FakeTransport) {
        let (m, log, t, _) = makeManagerWithLogs(dialTimeout: dialTimeout)
        return (m, log, t)
    }

    func makeManagerWithLogs(dialTimeout: TimeInterval = 60,
                             iceRestartDelay: TimeInterval = 3.0)
        -> (CallManager, SignalLog, FakeTransport, LogSink) {
        let log = SignalLog()
        let logs = LogSink()
        let transport = FakeTransport()
        let manager = CallManager(
            ownUserId: "me",
            sendSignal: { log.record($0, chatId: $1) },
            sendLog: { logs.record($0, chatId: $1) },
            makeTransport: { transport },
            dialTimeout: dialTimeout,
            iceRestartDelay: iceRestartDelay)
        return (manager, log, transport, logs)
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

    func testCallerLogsCompletedWithDuration() async {
        let (manager, log, transport, logs) = makeManagerWithLogs()
        await manager.startCall(chatId: "chat1", peerUserId: "peer")
        await manager.handle(event(CallSignal(type: .answer, callId: log.all[0].0.callId, sdp: "a")))
        transport.emit(.connected)
        try? await Task.sleep(nanoseconds: 150_000_000)
        await manager.hangUp()
        XCTAssertEqual(logs.all.count, 1)
        XCTAssertEqual(logs.all[0].0.outcome, .completed)
        XCTAssertEqual(logs.all[0].0.callId, log.all[0].0.callId)
        XCTAssertNotNil(logs.all[0].0.duration)
        XCTAssertEqual(logs.all[0].1, "chat1")
    }

    func testCallerLogsMissedOnTimeoutAndCancel() async {
        let (manager, _, _, logs) = makeManagerWithLogs(dialTimeout: 0.2)
        await manager.startCall(chatId: "chat1", peerUserId: "peer")
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(logs.all.map { $0.0.outcome }, [.missed])
        XCTAssertNil(logs.all[0].0.duration)

        await manager.reset()
        await manager.startCall(chatId: "chat1", peerUserId: "peer")
        await manager.hangUp() // gave up while dialing
        XCTAssertEqual(logs.all.map { $0.0.outcome }, [.missed, .missed])
    }

    func testCallerLogsDeclined() async {
        let (manager, log, _, logs) = makeManagerWithLogs()
        await manager.startCall(chatId: "chat1", peerUserId: "peer")
        await manager.handle(event(CallSignal(type: .end, callId: log.all[0].0.callId, reason: .decline)))
        XCTAssertEqual(logs.all.map { $0.0.outcome }, [.declined])
    }

    /// Only the caller publishes: the callee's side of the same call must not
    /// produce a second row.
    func testCalleeNeverLogs() async {
        let (manager, _, _, logs) = makeManagerWithLogs()
        await manager.handle(event(CallSignal(type: .offer, callId: "c1", sdp: "s")))
        await manager.decline()
        await manager.reset()
        await manager.handle(event(CallSignal(type: .offer, callId: "c2", sdp: "s")))
        await manager.accept()
        await manager.handle(event(CallSignal(type: .end, callId: "c2", reason: .hangup)))
        XCTAssertTrue(logs.all.isEmpty)
    }

    /// The callee's privacy gate: a shut-out caller is answered busy and the
    /// device never rings; an allowed one rings as usual.
    func testPrivacyGateAnswersBusyWithoutRinging() async {
        let log = SignalLog()
        let manager = CallManager(
            ownUserId: "me",
            sendSignal: { log.record($0, chatId: $1) },
            mayCall: { $0 == "friend" },
            makeTransport: { FakeTransport() })
        await manager.handle(event(CallSignal(type: .offer, callId: "c1", sdp: "s"), from: "stranger"))
        var state = await manager.current
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(log.types, [.end])
        XCTAssertEqual(log.all[0].0.reason, .busy)
        XCTAssertEqual(log.all[0].0.callId, "c1")

        await manager.handle(event(CallSignal(type: .offer, callId: "c2", sdp: "s"), from: "friend"))
        state = await manager.current
        XCTAssertEqual(state.phase, .ringing)
        XCTAssertEqual(state.callId, "c2")
    }

    /// Glare is not an incoming call: whoever this device just dialed is
    /// allowed to converge into one call whatever the privacy tier says.
    func testPrivacyGateDoesNotBreakGlare() async {
        let log = SignalLog()
        let transport = FakeTransport()
        let manager = CallManager(
            ownUserId: "me",
            sendSignal: { log.record($0, chatId: $1) },
            mayCall: { _ in false },
            makeTransport: { transport })
        await manager.startCall(chatId: "chat1", peerUserId: "peer")
        await manager.handle(event(CallSignal(type: .offer, callId: "!first", sdp: "their-offer")))
        let state = await manager.current
        XCTAssertEqual(state.phase, .connecting)
        XCTAssertEqual(state.callId, "!first")
    }

    func testMutePassesThrough() async {
        let (manager, _, transport) = makeManager()
        await manager.startCall(chatId: "chat1", peerUserId: "peer")
        await manager.setMuted(true)
        let state = await manager.current
        XCTAssertTrue(state.muted)
        XCTAssertEqual(transport.muted, true)
    }

    /// Brings a manager into the active phase as the caller.
    private func activateAsCaller(_ manager: CallManager, log: SignalLog,
                                  transport: FakeTransport) async {
        await manager.startCall(chatId: "chat1", peerUserId: "peer")
        await manager.handle(event(CallSignal(type: .answer, callId: log.all[0].0.callId,
                                              sdp: "their-answer")))
        transport.emit(.connected)
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    /// A disconnect that outlives the delay makes the caller send a fresh
    /// offer for the same call.
    func testDisconnectTriggersIceRestartOffer() async {
        let (manager, log, transport, _) = makeManagerWithLogs(iceRestartDelay: 0.05)
        await activateAsCaller(manager, log: log, transport: transport)
        transport.emit(.disconnected)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(transport.restarted)
        XCTAssertEqual(log.types, [.offer, .offer])
        XCTAssertEqual(log.all[1].0.callId, log.all[0].0.callId)
        XCTAssertEqual(log.all[1].0.sdp, "restart-sdp")
        let state = await manager.current
        XCTAssertEqual(state.phase, .active)
    }

    /// Media returning within the delay cancels the pending restart.
    func testReconnectWithinDelayCancelsRestart() async {
        let (manager, log, transport, _) = makeManagerWithLogs(iceRestartDelay: 0.2)
        await activateAsCaller(manager, log: log, transport: transport)
        transport.emit(.disconnected)
        try? await Task.sleep(nanoseconds: 50_000_000)
        transport.emit(.connected)
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(transport.restarted)
        XCTAssertEqual(log.types, [.offer])
    }

    /// The callee never restarts on its own: one side restarting keeps the
    /// offers from glaring.
    func testCalleeDoesNotRestart() async {
        let (manager, log, transport, _) = makeManagerWithLogs(iceRestartDelay: 0.05)
        await manager.handle(event(CallSignal(type: .offer, callId: "c1", sdp: "their-offer")))
        await manager.accept()
        transport.emit(.connected)
        try? await Task.sleep(nanoseconds: 100_000_000)
        transport.emit(.disconnected)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(transport.restarted)
        XCTAssertEqual(log.types, [.answer])
    }

    /// The callee answers a restart offer on the live transport, in place.
    func testRestartOfferAnsweredInPlace() async {
        let (manager, log, transport) = makeManager()
        await manager.handle(event(CallSignal(type: .offer, callId: "c1", sdp: "their-offer")))
        await manager.accept()
        transport.emit(.connected)
        try? await Task.sleep(nanoseconds: 100_000_000)
        await manager.handle(event(CallSignal(type: .offer, callId: "c1", sdp: "restart-offer")))
        XCTAssertEqual(transport.remoteOffer, "restart-offer")
        XCTAssertEqual(log.types, [.answer, .answer])
        let state = await manager.current
        XCTAssertEqual(state.phase, .active)
        XCTAssertFalse(transport.closed)
    }

    /// Turning the camera on adds the track and renegotiates the same call:
    /// a second offer with the same callId, answered on the live transport.
    func testCameraOnRenegotiates() async {
        let (manager, log, transport, _) = makeManagerWithLogs()
        await activateAsCaller(manager, log: log, transport: transport)
        await manager.setVideo(true)
        XCTAssertEqual(transport.videoEnabled, true)
        XCTAssertEqual(log.types, [.offer, .offer])
        XCTAssertEqual(log.all[1].0.callId, log.all[0].0.callId)
        let state = await manager.current
        XCTAssertTrue(state.localVideo)
        XCTAssertEqual(state.phase, .active)
    }

    /// The peer's camera reaching the transport shows up in the state.
    func testRemoteVideoReachesTheState() async {
        let (manager, log, transport, _) = makeManagerWithLogs()
        await activateAsCaller(manager, log: log, transport: transport)
        transport.emit(.remoteVideo(true))
        try? await Task.sleep(nanoseconds: 100_000_000)
        var state = await manager.current
        XCTAssertTrue(state.remoteVideo)
        await manager.hangUp()
        state = await manager.current
        XCTAssertFalse(state.remoteVideo)
    }

    /// The renegotiation offer carries whether the sender's camera is on;
    /// off reaches the peer as a state change, not a frozen last frame.
    func testRenegotiationOfferCarriesCameraState() async {
        let (manager, log, transport) = makeManager()
        await manager.handle(event(CallSignal(type: .offer, callId: "c1", sdp: "their-offer")))
        await manager.accept()
        transport.emit(.connected)
        try? await Task.sleep(nanoseconds: 100_000_000)
        await manager.handle(event(CallSignal(type: .offer, callId: "c1", sdp: "re1", video: true)))
        var state = await manager.current
        XCTAssertTrue(state.remoteVideo)
        await manager.handle(event(CallSignal(type: .offer, callId: "c1", sdp: "re2", video: false)))
        state = await manager.current
        XCTAssertFalse(state.remoteVideo)
        XCTAssertEqual(log.types, [.answer, .answer, .answer])
    }

    /// Candidates ride the relay and can outrun the journaled offer: they are
    /// held by callId and applied once the offer lands and the call is taken.
    func testCandidatesAheadOfTheirOfferAreHeld() async {
        let (manager, _, transport) = makeManager()
        let cand = CallSignal.IceCandidate(sdpMid: "0", sdpMLineIndex: 0, candidate: "cand-early")
        await manager.handle(event(CallSignal(type: .ice, callId: "c1", candidates: [cand])))
        await manager.handle(event(CallSignal(type: .offer, callId: "c1", sdp: "their-offer")))
        await manager.accept()
        XCTAssertEqual(transport.added.map(\.candidate), ["cand-early"])
    }

    // MARK: - Conference (a short-lived mesh of three)

    /// Collects every transport the factory hands out, so a test can address
    /// each leg of a conference.
    final class TransportFactoryLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [FakeTransport] = []
        func make() -> FakeTransport {
            let t = FakeTransport()
            lock.lock(); items.append(t); lock.unlock()
            return t
        }
        var all: [FakeTransport] {
            lock.lock(); defer { lock.unlock() }
            return items
        }
    }

    /// A conference manager with its own chat opener and invite-row sink.
    private func makeConferenceManager()
        -> (CallManager, SignalLog, TransportFactoryLog, invites: SignalLogStrings) {
        let log = SignalLog()
        let factory = TransportFactoryLog()
        let invites = SignalLogStrings()
        let manager = CallManager(
            ownUserId: "me",
            sendSignal: { log.record($0, chatId: $1) },
            makeTransport: { factory.make() },
            openChat: { userId in "direct:me-\(userId)" },
            sendInviteRow: { chatId, userId in invites.record("\(chatId)|\(userId)") },
            iceRestartDelay: 60)
        return (manager, log, factory, invites)
    }

    /// Collects the conference cards a manager writes, with their chats.
    final class CardSink: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(CallLive, String)] = []
        func record(_ card: CallLive, chatId: String) {
            lock.lock(); items.append((card, chatId)); lock.unlock()
        }
        var all: [(CallLive, String)] {
            lock.lock(); defer { lock.unlock() }
            return items
        }
    }

    private func makeCardManager(closed: SignalLogStrings = SignalLogStrings())
        -> (CallManager, SignalLog, TransportFactoryLog, CardSink) {
        let log = SignalLog()
        let factory = TransportFactoryLog()
        let cards = CardSink()
        let manager = CallManager(
            ownUserId: "me",
            sendSignal: { log.record($0, chatId: $1) },
            makeTransport: { factory.make() },
            openChat: { userId in "direct:me-\(userId)" },
            sendLiveCard: { cards.record($0, chatId: $1) },
            endLiveCards: { closed.record($0) },
            iceRestartDelay: 60)
        return (manager, log, factory, cards)
    }

    /// A participant's own call ending closes its copies of the call's cards
    /// locally, whether or not the writer's edit ever arrives; a call that
    /// never connected has no card to close.
    func testACallEndingClosesItsCardsLocally() async {
        let closed = SignalLogStrings()
        let (manager, log, factory, _) = makeCardManager(closed: closed)
        await manager.handle(event(CallSignal(type: .offer, callId: "c1", sdp: "s")))
        await manager.accept()
        factory.all[0].emit(.connected)
        try? await Task.sleep(nanoseconds: 100_000_000)
        await manager.handle(event(CallSignal(type: .end, callId: "c1", reason: .hangup)))
        XCTAssertEqual(closed.all, ["c1"])
        XCTAssertEqual(log.types, [.answer])

        let (ringing, _, _, _) = makeCardManager(closed: closed)
        await ringing.handle(event(CallSignal(type: .offer, callId: "c2", sdp: "s")))
        await ringing.decline()
        XCTAssertEqual(closed.all, ["c1"], "a declined ring closes nothing")
    }

    // MARK: - Rooms (a group call on the SFU)

    /// A room that joins instantly and records what it was told.
    final class FakeRoom: CallRoomSession, @unchecked Sendable {
        let lock = NSLock()
        var joined: (url: String, token: String, key: String, video: Bool)?
        var muted: Bool?
        var video: Bool?
        var left = false
        private var continuation: AsyncStream<CallRoomEvent>.Continuation?
        private let stream: AsyncStream<CallRoomEvent>

        init() {
            var c: AsyncStream<CallRoomEvent>.Continuation!
            stream = AsyncStream { c = $0 }
            continuation = c
        }

        func join(url: String, token: String, key: String, video: Bool) async throws {
            lock.lock(); joined = (url, token, key, video); lock.unlock()
        }
        func setMuted(_ muted: Bool) async { lock.lock(); self.muted = muted; lock.unlock() }
        func setVideo(enabled: Bool) async { lock.lock(); video = enabled; lock.unlock() }
        func leave() async {
            lock.lock(); left = true; lock.unlock()
            continuation?.finish()
        }
        func events() -> AsyncStream<CallRoomEvent> { stream }
        func emit(_ event: CallRoomEvent) { continuation?.yield(event) }
    }

    /// A manager with a room behind it: tickets are recorded as
    /// «callId|chatId», the room and the 1:1 transports come from logs.
    private func makeRoomManager(closed: SignalLogStrings = SignalLogStrings())
        -> (CallManager, SignalLog, FakeRoom, TransportFactoryLog, CardSink, tickets: SignalLogStrings,
            invites: SignalLogStrings) {
        let log = SignalLog()
        let factory = TransportFactoryLog()
        let cards = CardSink()
        let tickets = SignalLogStrings()
        let invites = SignalLogStrings()
        let room = FakeRoom()
        let manager = CallManager(
            ownUserId: "me",
            sendSignal: { log.record($0, chatId: $1) },
            makeTransport: { factory.make() },
            makeRoom: { room },
            fetchTicket: { callId, chatId in
                tickets.record("\(callId)|\(chatId)")
                return CallRoomTicket(url: "wss://sfu", token: "tok")
            },
            openChat: { userId in "direct:me-\(userId)" },
            sendInviteRow: { chatId, userId in invites.record("\(chatId)|\(userId)") },
            sendLiveCard: { cards.record($0, chatId: $1) },
            endLiveCards: { closed.record($0) },
            iceRestartDelay: 60)
        return (manager, log, room, factory, cards, tickets, invites)
    }

    /// The group's call: a ticket for the chat, the room joined under a fresh
    /// key, the `room` invite into the chat with that key, the card in the
    /// chat with the key too. Dialing until the first person walks in.
    func testGroupCallOpensTheRoomAndRingsTheChat() async {
        let (manager, log, room, _, cards, tickets, _) = makeRoomManager()
        await manager.startGroupCall(chatId: "grp")
        var state = await manager.current
        XCTAssertEqual(state.phase, .dialing)
        XCTAssertTrue(state.isRoom)
        XCTAssertNil(state.peerUserId)
        XCTAssertEqual(tickets.all, ["\(state.callId!)|grp"])
        XCTAssertEqual(room.joined?.url, "wss://sfu")
        XCTAssertEqual(room.joined?.token, "tok")
        XCTAssertEqual(room.joined?.video, false)
        XCTAssertEqual(log.types, [.room])
        XCTAssertEqual(log.all[0].1, "grp")
        XCTAssertEqual(log.all[0].0.key, room.joined?.key)
        XCTAssertNotNil(room.joined?.key)
        XCTAssertEqual(cards.all.count, 1)
        XCTAssertEqual(cards.all[0].1, "grp")
        XCTAssertEqual(cards.all[0].0.key, room.joined?.key)
        XCTAssertEqual(cards.all[0].0.memberIds, ["me"])

        room.emit(.participants([CallParticipant(userId: "zed")]))
        try? await Task.sleep(nanoseconds: 100_000_000)
        state = await manager.current
        XCTAssertEqual(state.phase, .active)
        XCTAssertNotNil(state.connectedAt)
        XCTAssertEqual(state.participants.map(\.userId), ["zed"])
        XCTAssertEqual(cards.all.last?.0.memberIds, ["me", "zed"], "the writer keeps the card current")
    }

    /// The invited side: the `room` invite rings like an offer, and accepting
    /// it walks into the room — a ticket for the chat the invite came over,
    /// the room joined under the invite's key — with a bare answer on the
    /// wire for this account's other devices.
    func testRoomInviteRingsAndJoins() async {
        let (manager, log, room, _, _, tickets, _) = makeRoomManager()
        await manager.handle(event(CallSignal(type: .room, callId: "c1", key: "k1"),
                                   chatId: "grp", from: "alice"))
        var state = await manager.current
        XCTAssertEqual(state.phase, .ringing)
        XCTAssertTrue(state.isRoom)
        XCTAssertEqual(state.peerUserId, "alice")

        await manager.accept()
        state = await manager.current
        XCTAssertEqual(state.phase, .active)
        XCTAssertNotNil(state.connectedAt)
        XCTAssertEqual(tickets.all, ["c1|grp"])
        XCTAssertEqual(room.joined?.key, "k1")
        XCTAssertEqual(log.types, [.answer])
        XCTAssertNil(log.all[0].0.sdp)
        XCTAssertEqual(log.all[0].1, "grp")
    }

    /// A stale invite does not ring, exactly as a stale offer does not.
    func testStaleRoomInviteIsNotFresh() {
        let now = Date().timeIntervalSince1970
        let invite = CallSignal(type: .room, callId: "c1", key: "k")
        XCTAssertTrue(invite.isFresh(sentAt: now - 30, now: now))
        XCTAssertFalse(invite.isFresh(sentAt: now - 61, now: now))
    }

    /// In a room the roster is the SFU's word: a member declining the invite,
    /// or answering busy, changes nothing for the one who opened it.
    func testDeclineOfARoomInviteLeavesTheOpenerAlone() async {
        let (manager, _, room, _, _, _, _) = makeRoomManager()
        await manager.startGroupCall(chatId: "grp")
        let callId = await manager.current.callId!
        room.emit(.participants([CallParticipant(userId: "zed")]))
        try? await Task.sleep(nanoseconds: 100_000_000)
        await manager.handle(event(CallSignal(type: .end, callId: callId, reason: .decline),
                                   chatId: "grp", from: "bob"))
        await manager.handle(event(CallSignal(type: .end, callId: callId, reason: .busy),
                                   chatId: "grp", from: "carol"))
        let state = await manager.current
        XCTAssertEqual(state.phase, .active)
        XCTAssertFalse(room.left)
    }

    /// Pulling someone into a 1:1 call moves it into a room: the peer gets the
    /// key over the chat before the transport closes, this device joins the
    /// room, and then the invite goes to the new person over their chat with
    /// the same key, the invited-by row and the card in both chats.
    func testInviteFromAOneToOneCallMovesItIntoARoom() async {
        let (manager, log, room, factory, cards, tickets, invites) = makeRoomManager()
        await manager.startCall(chatId: "chat1", peerUserId: "peer")
        let callId = log.all[0].0.callId
        await manager.handle(event(CallSignal(type: .answer, callId: callId, sdp: "a")))
        factory.all[0].emit(.connected)
        try? await Task.sleep(nanoseconds: 100_000_000)

        await manager.invite(userId: "carol")
        let state = await manager.current
        XCTAssertEqual(state.phase, .active)
        XCTAssertTrue(state.isRoom)
        XCTAssertEqual(state.callId, callId)
        XCTAssertTrue(factory.all[0].closed)
        XCTAssertEqual(tickets.all, ["\(callId)|chat1"])
        let rooms = log.all.filter { $0.0.type == .room }
        XCTAssertEqual(rooms.map(\.1), ["chat1", "direct:me-carol"])
        XCTAssertEqual(rooms[0].0.key, room.joined?.key)
        XCTAssertEqual(rooms[1].0.key, room.joined?.key)
        XCTAssertTrue(rooms.allSatisfy { $0.0.callId == callId })
        XCTAssertEqual(invites.all, ["direct:me-carol|carol"])
        XCTAssertEqual(Set(cards.all.map(\.1)), ["chat1", "direct:me-carol"])
        XCTAssertTrue(cards.all.allSatisfy { $0.0.key == room.joined?.key && $0.0.isLive })
    }

    /// The peer's side of that move: the `room` signal for the running call
    /// closes the transport and joins the room under the peer's key; the
    /// call stands throughout.
    func testPeerFollowsTheCallIntoTheRoom() async {
        let (manager, log, room, factory, _, tickets, _) = makeRoomManager()
        await manager.handle(event(CallSignal(type: .offer, callId: "c1", sdp: "s")))
        await manager.accept()
        factory.all[0].emit(.connected)
        try? await Task.sleep(nanoseconds: 100_000_000)

        await manager.handle(event(CallSignal(type: .room, callId: "c1", key: "k9")))
        let state = await manager.current
        XCTAssertEqual(state.phase, .active)
        XCTAssertTrue(state.isRoom)
        XCTAssertTrue(factory.all[0].closed)
        XCTAssertEqual(room.joined?.key, "k9")
        XCTAssertEqual(tickets.all, ["c1|chat1"])
        XCTAssertEqual(log.types, [.answer], "no signaling answers a room")
    }

    /// A tap on a live card joins the room under the card's key; a card with
    /// no key, or an ended one, is not joinable.
    func testJoinFromTheCardWalksIntoTheRoom() async {
        let (manager, log, room, _, cards, tickets, _) = makeRoomManager()
        let card = CallLive(callId: "c1", startedAt: 100,
                            members: [.init(id: "alice", name: "Alice")], key: "kc")
        await manager.join(card, chatId: "grp", hostUserId: "alice")
        let state = await manager.current
        XCTAssertEqual(state.phase, .active)
        XCTAssertTrue(state.isRoom)
        XCTAssertEqual(state.callId, "c1")
        XCTAssertEqual(room.joined?.key, "kc")
        XCTAssertEqual(tickets.all, ["c1|grp"])
        XCTAssertTrue(log.all.isEmpty)
        XCTAssertTrue(cards.all.isEmpty, "the joiner writes no card of its own")

        let (idle, _, idleRoom, _, _, _, _) = makeRoomManager()
        var ended = card
        ended.endedAt = 200
        await idle.join(ended, chatId: "grp", hostUserId: "alice")
        var keyless = card
        keyless.key = nil
        await idle.join(keyless, chatId: "grp", hostUserId: "alice")
        let idleState = await idle.current
        XCTAssertEqual(idleState.phase, .idle)
        XCTAssertNil(idleRoom.joined)
    }

    /// Leaving a room with people still in it leaves the room and its card
    /// alone: no end on the wire, no closing edit. The last one out closes
    /// the card, in the chat and locally.
    func testLastOneOutClosesTheCard() async {
        let closed = SignalLogStrings()
        let (manager, log, room, _, cards, _, _) = makeRoomManager(closed: closed)
        await manager.handle(event(CallSignal(type: .room, callId: "c1", key: "k1"),
                                   chatId: "grp", from: "alice"))
        await manager.accept()
        room.emit(.participants([CallParticipant(userId: "alice")]))
        try? await Task.sleep(nanoseconds: 100_000_000)
        await manager.hangUp()
        XCTAssertTrue(room.left)
        XCTAssertEqual(log.types, [.answer], "nobody is told; the room lives on")
        XCTAssertTrue(cards.all.isEmpty)
        XCTAssertTrue(closed.all.isEmpty)

        let (last, lastLog, lastRoom, _, lastCards, _, _) = makeRoomManager(closed: closed)
        await last.handle(event(CallSignal(type: .room, callId: "c2", key: "k2"),
                                chatId: "grp", from: "alice"))
        await last.accept()
        lastRoom.emit(.participants([CallParticipant(userId: "alice")]))
        try? await Task.sleep(nanoseconds: 100_000_000)
        lastRoom.emit(.participants([]))
        try? await Task.sleep(nanoseconds: 100_000_000)
        await last.hangUp()
        XCTAssertEqual(lastLog.types, [.answer])
        // alice leaving made this device the writer: one card with itself
        // alone, then the closing one
        XCTAssertEqual(lastCards.all.map(\.0.memberIds), [["me"], ["me"]])
        XCTAssertEqual(lastCards.all.map(\.1), ["grp", "grp"])
        XCTAssertNil(lastCards.all[0].0.endedAt)
        XCTAssertNotNil(lastCards.all[1].0.endedAt)
        XCTAssertEqual(lastCards.all[1].0.key, "k2")
        XCTAssertEqual(closed.all, ["c2"])
    }

    /// A room left empty ends on its own after the timeout, and its card
    /// closes: the reader of a card whose call died with its last
    /// participant's app is not left standing in an empty room.
    func testEmptyRoomEndsAndClosesTheCard() async {
        let log = SignalLog()
        let cards = CardSink()
        let closed = SignalLogStrings()
        let room = FakeRoom()
        let manager = CallManager(
            ownUserId: "me",
            sendSignal: { log.record($0, chatId: $1) },
            makeTransport: { FakeTransport() },
            makeRoom: { room },
            fetchTicket: { _, _ in CallRoomTicket(url: "wss://sfu", token: "tok") },
            sendLiveCard: { cards.record($0, chatId: $1) },
            endLiveCards: { closed.record($0) },
            emptyRoomTimeout: 0.1)
        let card = CallLive(callId: "c1", startedAt: 100,
                            members: [.init(id: "alice", name: "Alice")], key: "kc")
        await manager.join(card, chatId: "grp", hostUserId: "alice")
        room.emit(.participants([]))
        try? await Task.sleep(nanoseconds: 400_000_000)
        let state = await manager.current
        XCTAssertEqual(state.phase, .ended(.hangup))
        XCTAssertTrue(room.left)
        XCTAssertEqual(cards.all.count, 1)
        XCTAssertNotNil(cards.all[0].0.endedAt)
        XCTAssertEqual(closed.all, ["c1"])
        XCTAssertTrue(log.all.isEmpty)
    }

    /// The opener still alone in the room hanging up cancels the ringing
    /// everywhere and closes the card; the room session is left.
    func testOpenerAloneCancelsTheRing() async {
        let (manager, log, room, _, cards, _, _) = makeRoomManager()
        await manager.startGroupCall(chatId: "grp")
        await manager.hangUp()
        let ends = log.all.filter { $0.0.type == .end }
        XCTAssertEqual(ends.count, 1)
        XCTAssertEqual(ends[0].0.reason, .cancel)
        XCTAssertEqual(ends[0].1, "grp")
        XCTAssertTrue(room.left)
        XCTAssertNotNil(cards.all.last?.0.endedAt)
    }

    /// The caller applies the answer to its restart offer without leaving the
    /// active phase.
    func testRestartAnswerAcceptedWhileActive() async {
        let (manager, log, transport, _) = makeManagerWithLogs(iceRestartDelay: 0.05)
        await activateAsCaller(manager, log: log, transport: transport)
        transport.emit(.disconnected)
        try? await Task.sleep(nanoseconds: 300_000_000)
        await manager.handle(event(CallSignal(type: .answer, callId: log.all[0].0.callId,
                                              sdp: "restart-answer")))
        XCTAssertEqual(transport.remoteAnswer, "restart-answer")
        let state = await manager.current
        XCTAssertEqual(state.phase, .active)
    }

    /// Puts the manager on a standing call as the callee, over the factory's
    /// first transport, and lands a second caller's offer behind it.
    private func activateWithWaiting(_ manager: CallManager, log: SignalLog,
                                     factory: TransportFactoryLog) async {
        await manager.handle(event(CallSignal(type: .offer, callId: "c1", sdp: "s")))
        await manager.accept()
        factory.all[0].emit(.connected)
        try? await Task.sleep(nanoseconds: 100_000_000)
        await manager.handle(event(CallSignal(type: .offer, callId: "c2", sdp: "s2"),
                                   chatId: "chat2", from: "second"))
    }

    /// A second caller during a standing call waits on the screen instead of
    /// being answered busy.
    func testSecondCallerWaitsInsteadOfBusy() async {
        let (manager, log, factory, _) = makeConferenceManager()
        await activateWithWaiting(manager, log: log, factory: factory)
        let state = await manager.current
        XCTAssertEqual(state.phase, .active)
        XCTAssertEqual(state.waitingCallerId, "second")
        XCTAssertFalse(log.types.contains(.end))
    }

    /// Refusing the waiter answers them busy and the call stands untouched.
    func testDeclineWaitingSendsBusy() async {
        let (manager, log, factory, _) = makeConferenceManager()
        await activateWithWaiting(manager, log: log, factory: factory)
        await manager.declineWaiting()
        let state = await manager.current
        XCTAssertEqual(state.phase, .active)
        XCTAssertNil(state.waitingCallerId)
        let end = log.all.last!
        XCTAssertEqual(end.0.type, .end)
        XCTAssertEqual(end.0.callId, "c2")
        XCTAssertEqual(end.0.reason, .busy)
        XCTAssertEqual(end.1, "chat2")
        XCTAssertFalse(factory.all[0].closed)
    }

    /// Trading the call for the waiter: the live call is hung up over its own
    /// chat and the waiter's offer is answered on a fresh transport.
    func testAcceptWaitingSwapsTheCall() async {
        let (manager, log, factory, _) = makeConferenceManager()
        await activateWithWaiting(manager, log: log, factory: factory)
        await manager.acceptWaiting()
        let state = await manager.current
        XCTAssertEqual(state.phase, .connecting)
        XCTAssertEqual(state.peerUserId, "second")
        XCTAssertEqual(state.chatId, "chat2")
        XCTAssertEqual(state.callId, "c2")
        XCTAssertNil(state.waitingCallerId)
        let hangup = log.all.first { $0.0.type == .end }!
        XCTAssertEqual(hangup.0.callId, "c1")
        XCTAssertEqual(hangup.0.reason, .hangup)
        XCTAssertEqual(hangup.1, "chat1")
        XCTAssertTrue(factory.all[0].closed)
        XCTAssertEqual(factory.all[1].remoteOffer, "s2")
        let answer = log.all.last!
        XCTAssertEqual(answer.0.type, .answer)
        XCTAssertEqual(answer.1, "chat2")
    }

    /// The waiter hanging up on their side clears the banner, nothing else.
    func testWaiterCancelClearsTheBanner() async {
        let (manager, log, factory, _) = makeConferenceManager()
        await activateWithWaiting(manager, log: log, factory: factory)
        await manager.handle(event(CallSignal(type: .end, callId: "c2", reason: .cancel),
                                   chatId: "chat2", from: "second"))
        let state = await manager.current
        XCTAssertEqual(state.phase, .active)
        XCTAssertNil(state.waitingCallerId)
        XCTAssertFalse(factory.all[0].closed)
        _ = log
    }

    /// The live call ending on its own promotes the waiter to ringing.
    func testPeerEndPromotesWaiterToRinging() async {
        let (manager, log, factory, _) = makeConferenceManager()
        await activateWithWaiting(manager, log: log, factory: factory)
        await manager.handle(event(CallSignal(type: .end, callId: "c1", reason: .hangup)))
        let state = await manager.current
        XCTAssertEqual(state.phase, .ringing)
        XCTAssertEqual(state.peerUserId, "second")
        XCTAssertEqual(state.callId, "c2")
        XCTAssertNil(state.waitingCallerId)
        await manager.accept()
        XCTAssertEqual(factory.all[1].remoteOffer, "s2")
        _ = log
    }

    /// Hold-and-accept parks the live call on its open transport, tells its
    /// peer, and answers the waiter.
    func testHoldAndAcceptParksTheCall() async {
        let (manager, log, factory, _) = makeConferenceManager()
        await activateWithWaiting(manager, log: log, factory: factory)
        await manager.holdAndAcceptWaiting()
        let state = await manager.current
        XCTAssertEqual(state.phase, .connecting)
        XCTAssertEqual(state.peerUserId, "second")
        XCTAssertEqual(state.heldPeerId, "peer")
        XCTAssertNil(state.waitingCallerId)
        XCTAssertFalse(factory.all[0].closed)
        XCTAssertEqual(factory.all[0].held, true)
        let hold = log.all.first { $0.0.type == .hold }!
        XCTAssertEqual(hold.0.callId, "c1")
        XCTAssertEqual(hold.0.held, true)
        XCTAssertEqual(hold.1, "chat1")
        XCTAssertEqual(log.all.last!.0.type, .answer)
        XCTAssertEqual(log.all.last!.1, "chat2")
    }

    /// Switching swaps the two calls: the live one parks, the parked one
    /// speaks again, and both peers are told.
    func testSwitchToHeldSwapsTheCalls() async {
        let (manager, log, factory, _) = makeConferenceManager()
        await activateWithWaiting(manager, log: log, factory: factory)
        await manager.holdAndAcceptWaiting()
        factory.all[1].emit(.connected)
        try? await Task.sleep(nanoseconds: 100_000_000)
        await manager.switchToHeld()
        let state = await manager.current
        XCTAssertEqual(state.phase, .active)
        XCTAssertEqual(state.peerUserId, "peer")
        XCTAssertEqual(state.chatId, "chat1")
        XCTAssertEqual(state.heldPeerId, "second")
        XCTAssertEqual(factory.all[0].held, false)
        XCTAssertEqual(factory.all[1].held, true)
        let holds = log.all.filter { $0.0.type == .hold }
        XCTAssertEqual(holds.last!.0.held, false)
        XCTAssertEqual(holds.last!.1, "chat1")
    }

    /// Hanging up the live call brings the parked one back.
    func testHangUpUnparksTheHeldCall() async {
        let (manager, log, factory, _) = makeConferenceManager()
        await activateWithWaiting(manager, log: log, factory: factory)
        await manager.holdAndAcceptWaiting()
        factory.all[1].emit(.connected)
        try? await Task.sleep(nanoseconds: 100_000_000)
        await manager.hangUp()
        let state = await manager.current
        XCTAssertEqual(state.phase, .active)
        XCTAssertEqual(state.peerUserId, "peer")
        XCTAssertNil(state.heldPeerId)
        XCTAssertEqual(factory.all[0].held, false)
        XCTAssertTrue(factory.all[1].closed)
        _ = log
    }

    /// The parked call's peer hanging up empties the hold slot; the live
    /// call stands.
    func testHeldPeerEndDropsOnlyTheHeldCall() async {
        let (manager, log, factory, _) = makeConferenceManager()
        await activateWithWaiting(manager, log: log, factory: factory)
        await manager.holdAndAcceptWaiting()
        factory.all[1].emit(.connected)
        try? await Task.sleep(nanoseconds: 100_000_000)
        await manager.handle(event(CallSignal(type: .end, callId: "c1", reason: .hangup)))
        let state = await manager.current
        XCTAssertEqual(state.phase, .active)
        XCTAssertEqual(state.peerUserId, "second")
        XCTAssertNil(state.heldPeerId)
        XCTAssertTrue(factory.all[0].closed)
        XCTAssertFalse(factory.all[1].closed)
        _ = log
    }

    /// The peer's hold signal shows as their silence, on and off.
    func testRemoteHoldReachesTheState() async {
        let (manager, log, factory, _) = makeConferenceManager()
        await manager.handle(event(CallSignal(type: .offer, callId: "c1", sdp: "s")))
        await manager.accept()
        factory.all[0].emit(.connected)
        try? await Task.sleep(nanoseconds: 100_000_000)
        await manager.handle(event(CallSignal(type: .hold, callId: "c1", held: true)))
        var state = await manager.current
        XCTAssertTrue(state.remoteHold)
        await manager.handle(event(CallSignal(type: .hold, callId: "c1", held: false)))
        state = await manager.current
        XCTAssertFalse(state.remoteHold)
        _ = log
    }

    /// A second offer while merely ringing is still answered busy: nothing
    /// stands to wait behind.
    func testSecondOfferWhileRingingStaysBusy() async {
        let (manager, log, _, _) = makeConferenceManager()
        await manager.handle(event(CallSignal(type: .offer, callId: "c1", sdp: "s")))
        await manager.handle(event(CallSignal(type: .offer, callId: "c2", sdp: "s2"),
                                   chatId: "chat2", from: "second"))
        let state = await manager.current
        XCTAssertEqual(state.phase, .ringing)
        XCTAssertNil(state.waitingCallerId)
        XCTAssertEqual(log.all.last!.0.reason, .busy)
    }
}
