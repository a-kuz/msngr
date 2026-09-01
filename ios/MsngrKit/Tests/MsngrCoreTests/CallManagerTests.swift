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

    private func makeCardManager() -> (CallManager, SignalLog, TransportFactoryLog, CardSink) {
        let log = SignalLog()
        let factory = TransportFactoryLog()
        let cards = CardSink()
        let manager = CallManager(
            ownUserId: "me",
            sendSignal: { log.record($0, chatId: $1) },
            makeTransport: { factory.make() },
            openChat: { userId in "direct:me-\(userId)" },
            sendLiveCard: { cards.record($0, chatId: $1) },
            iceRestartDelay: 60)
        return (manager, log, factory, cards)
    }

    /// The inviter writes the live card into the chat the call started in and
    /// into the invited person's chat, naming everyone in the call.
    func testInviteLeavesTheLiveCardInBothChats() async {
        let (manager, log, factory, cards) = makeCardManager()
        await manager.startCall(chatId: "chat1", peerUserId: "peer")
        await manager.handle(event(CallSignal(type: .answer, callId: log.all[0].0.callId, sdp: "a")))
        factory.all[0].emit(.connected)
        try? await Task.sleep(nanoseconds: 100_000_000)

        await manager.invite(userId: "carol")
        XCTAssertEqual(Set(cards.all.map(\.1)), ["chat1", "direct:me-carol"])
        for (card, _) in cards.all {
            XCTAssertEqual(card.callId, log.all[0].0.callId)
            XCTAssertEqual(Set(card.memberIds), ["me", "peer", "carol"])
            XCTAssertTrue(card.isLive)
        }
    }

    /// Hanging up closes every card this device wrote, once, and nothing is
    /// written after that.
    func testHangUpClosesTheLiveCards() async {
        let (manager, log, factory, cards) = makeCardManager()
        await manager.startCall(chatId: "chat1", peerUserId: "peer")
        await manager.handle(event(CallSignal(type: .answer, callId: log.all[0].0.callId, sdp: "a")))
        factory.all[0].emit(.connected)
        try? await Task.sleep(nanoseconds: 100_000_000)
        await manager.invite(userId: "carol")
        let before = cards.all.count

        await manager.hangUp()
        let after = Array(cards.all.dropFirst(before))
        XCTAssertEqual(Set(after.map(\.1)), ["chat1", "direct:me-carol"])
        XCTAssertEqual(after.count, 2, "one closing card per chat, none for the legs torn down after")
        XCTAssertTrue(after.allSatisfy { $0.0.endedAt != nil })
    }

    /// A member of neither chat with no card of their own — the invited
    /// person, say — reads the card and joins: an offer with the card's callId
    /// to its writer over this chat, and a leg to every other member.
    func testJoinFromTheCardDialsTheWriterAndTheMembers() async {
        let (manager, log, _, cards) = makeCardManager()
        let card = CallLive(callId: "c1", startedAt: 100,
                            members: [.init(id: "alice", name: "Alice"), .init(id: "bob", name: "Bob")])
        await manager.join(card, chatId: "direct:me-alice", hostUserId: "alice")
        let state = await manager.current
        XCTAssertEqual(state.phase, .dialing)
        XCTAssertEqual(state.callId, "c1")
        XCTAssertEqual(state.peerUserId, "alice")
        XCTAssertEqual(state.extraPeers, ["bob"])
        XCTAssertEqual(log.types, [.offer, .offer])
        XCTAssertEqual(log.all.map(\.1), ["direct:me-alice", "direct:me-bob"])
        XCTAssertTrue(log.all.allSatisfy { $0.0.callId == "c1" })
        XCTAssertTrue(cards.all.isEmpty, "the joiner writes no card of its own")

        // an ended card is not joinable
        let (idle, idleLog, _, _) = makeCardManager()
        var ended = card
        ended.endedAt = 200
        await idle.join(ended, chatId: "direct:me-alice", hostUserId: "alice")
        let idleState = await idle.current
        XCTAssertEqual(idleState.phase, .idle)
        XCTAssertTrue(idleLog.all.isEmpty)
    }

    /// The inviter: a second leg opens toward the invited person, the offer
    /// names everyone already in, and the invited-by row lands in their chat.
    func testInviteOpensALegAndLeavesTheRow() async {
        let (manager, log, factory, invites) = makeConferenceManager()
        await manager.startCall(chatId: "chat1", peerUserId: "peer")
        await manager.handle(event(CallSignal(type: .answer, callId: log.all[0].0.callId,
                                              sdp: "a")))
        factory.all[0].emit(.connected)
        try? await Task.sleep(nanoseconds: 100_000_000)

        await manager.invite(userId: "carol")
        let state = await manager.current
        XCTAssertEqual(state.extraPeers, ["carol"])
        let inviteOffer = log.all.last!
        XCTAssertEqual(inviteOffer.0.type, .offer)
        XCTAssertEqual(inviteOffer.1, "direct:me-carol")
        XCTAssertEqual(inviteOffer.0.callId, log.all[0].0.callId)
        XCTAssertEqual(Set(inviteOffer.0.members ?? []), ["me", "peer"])
        XCTAssertEqual(invites.all, ["direct:me-carol|carol"])
    }

    /// The invited side: accepting an offer that names the members dials the
    /// ones it has no leg to yet, over their direct chats.
    func testJoinerDialsTheOtherMembers() async {
        let (manager, log, _, _) = makeConferenceManager()
        await manager.handle(event(CallSignal(type: .offer, callId: "c1", sdp: "s",
                                              members: ["alice", "bob"]),
                                   chatId: "direct:me-alice", from: "alice"))
        await manager.accept()
        let state = await manager.current
        XCTAssertEqual(state.extraPeers, ["bob"])
        XCTAssertEqual(log.types, [.answer, .offer])
        XCTAssertEqual(log.all[1].1, "direct:me-bob")
        XCTAssertEqual(log.all[1].0.callId, "c1")
    }

    /// The third leg reaching an existing participant: a same-callId offer
    /// from someone new joins in place — the callId is the ticket — with no
    /// ringing and no busy.
    func testSameCallIdOfferFromNewUserJoins() async {
        let (manager, log, factory, _) = makeConferenceManager()
        await manager.handle(event(CallSignal(type: .offer, callId: "c1", sdp: "s")))
        await manager.accept()
        factory.all[0].emit(.connected)
        try? await Task.sleep(nanoseconds: 100_000_000)

        await manager.handle(event(CallSignal(type: .offer, callId: "c1", sdp: "carol-sdp"),
                                   chatId: "direct:me-carol", from: "carol"))
        let state = await manager.current
        XCTAssertEqual(state.phase, .active)
        XCTAssertEqual(state.extraPeers, ["carol"])
        XCTAssertEqual(factory.all.count, 2)
        XCTAssertEqual(factory.all[1].remoteOffer, "carol-sdp")
        XCTAssertEqual(log.types, [.answer, .answer])
        XCTAssertEqual(log.all[1].1, "direct:me-carol")
    }

    /// A participant leaving takes their leg; the call stands.
    func testExtraLeavingKeepsTheCall() async {
        let (manager, log, factory, _) = makeConferenceManager()
        await manager.handle(event(CallSignal(type: .offer, callId: "c1", sdp: "s")))
        await manager.accept()
        factory.all[0].emit(.connected)
        try? await Task.sleep(nanoseconds: 100_000_000)
        await manager.handle(event(CallSignal(type: .offer, callId: "c1", sdp: "cs"),
                                   chatId: "direct:me-carol", from: "carol"))
        await manager.handle(event(CallSignal(type: .end, callId: "c1", reason: .hangup),
                                   chatId: "direct:me-carol", from: "carol"))
        let state = await manager.current
        XCTAssertEqual(state.phase, .active)
        XCTAssertEqual(state.extraPeers, [])
        XCTAssertTrue(factory.all[1].closed)
        _ = log
    }

    /// The primary peer leaving a conference promotes the oldest extra leg:
    /// the call keeps standing on it.
    func testPrimaryLeavingPromotesTheExtra() async {
        let (manager, _, factory, _) = makeConferenceManager()
        await manager.handle(event(CallSignal(type: .offer, callId: "c1", sdp: "s"),
                                   from: "alice"))
        await manager.accept()
        factory.all[0].emit(.connected)
        try? await Task.sleep(nanoseconds: 100_000_000)
        await manager.handle(event(CallSignal(type: .offer, callId: "c1", sdp: "cs"),
                                   chatId: "direct:me-carol", from: "carol"))
        await manager.handle(event(CallSignal(type: .end, callId: "c1", reason: .hangup),
                                   chatId: "chat1", from: "alice"))
        let state = await manager.current
        XCTAssertEqual(state.phase, .active)
        XCTAssertEqual(state.peerUserId, "carol")
        XCTAssertEqual(state.chatId, "direct:me-carol")
        XCTAssertEqual(state.extraPeers, [])
        XCTAssertTrue(factory.all[0].closed)
        XCTAssertFalse(factory.all[1].closed)
    }

    /// Hanging up a conference tells every leg over its own chat.
    func testHangUpEndsEveryLeg() async {
        let (manager, log, factory, _) = makeConferenceManager()
        await manager.handle(event(CallSignal(type: .offer, callId: "c1", sdp: "s")))
        await manager.accept()
        factory.all[0].emit(.connected)
        try? await Task.sleep(nanoseconds: 100_000_000)
        await manager.handle(event(CallSignal(type: .offer, callId: "c1", sdp: "cs"),
                                   chatId: "direct:me-carol", from: "carol"))
        await manager.hangUp()
        let ends = log.all.filter { $0.0.type == .end }
        XCTAssertEqual(Set(ends.map(\.1)), ["chat1", "direct:me-carol"])
        XCTAssertTrue(factory.all.allSatisfy(\.closed))
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
