import Foundation

/// What the media layer reports back to the call machinery.
public enum CallTransportEvent: Sendable {
    /// locally gathered ICE candidates, to be trickled to the peer
    case candidates([CallSignal.IceCandidate])
    /// media is flowing
    case connected
    /// media stopped flowing; the transport keeps trying
    case disconnected
    /// the transport gave up
    case failed
}

/// The media half of a call: SDP, ICE and audio live here. The production
/// implementation wraps a WebRTC peer connection; tests use a fake. One
/// transport serves one call and is closed with it.
public protocol CallMediaTransport: AnyObject, Sendable {
    /// caller: builds the local offer
    func makeOffer() async throws -> String
    /// caller: builds a fresh offer with new ICE credentials, for the restart
    /// after a network change; the peer answers it like any other offer
    func restartOffer() async throws -> String
    /// caller: applies the peer's answer
    func acceptAnswer(_ sdp: String) async throws
    /// callee: applies the peer's offer and builds the answer
    func answerOffer(_ sdp: String) async throws -> String
    func add(candidates: [CallSignal.IceCandidate]) async
    func setMuted(_ muted: Bool) async
    func close() async
    func events() -> AsyncStream<CallTransportEvent>
}

public enum CallPhase: Equatable, Sendable {
    case idle
    /// outgoing: the offer is out, nobody has answered yet
    case dialing
    /// incoming: the offer is here, the user has not decided yet
    case ringing
    /// both sides agreed, ICE is finding a path
    case connecting
    /// media is flowing
    case active
    /// over; the UI shows why briefly, then `reset()` returns to idle
    case ended(CallSignal.EndReason)
}

/// The call as the UI sees it.
public struct CallState: Equatable, Sendable {
    public var phase: CallPhase = .idle
    public var chatId: String?
    public var peerUserId: String?
    public var callId: String?
    public var muted = false
    /// when media started flowing, for the duration timer
    public var connectedAt: Double?

    public init(phase: CallPhase = .idle, chatId: String? = nil, peerUserId: String? = nil,
                callId: String? = nil, muted: Bool = false, connectedAt: Double? = nil) {
        self.phase = phase
        self.chatId = chatId
        self.peerUserId = peerUserId
        self.callId = callId
        self.muted = muted
        self.connectedAt = connectedAt
    }
}

/// Runs the one call this device can be in: dials, rings, answers, trickles
/// ICE, and closes. Signals go out through the SyncEngine as E2EE service
/// content and come back on its `callSignalStream`; media is behind
/// `CallMediaTransport`.
///
/// Glare — both sides dialing the same chat at once — is settled without a
/// human: the call with the smaller id survives as the call, the other side
/// cancels its own offer and answers the surviving one.
public actor CallManager {
    public typealias TransportFactory = @Sendable () throws -> CallMediaTransport
    public typealias SignalSender = @Sendable (CallSignal, String) async -> Void
    public typealias LogSender = @Sendable (CallLog, String) async -> Void
    /// Whether this user's call-privacy setting lets `userId` ring this
    /// device. Judged on the callee: the signaling is E2EE, so no server can.
    public typealias CallGate = @Sendable (_ userId: String) async -> Bool

    public nonisolated let stateStream = Broadcast<CallState>(initial: CallState())

    private let ownUserId: String
    private let sendSignal: SignalSender
    private let sendLog: LogSender
    private let mayCall: CallGate
    private let makeTransport: TransportFactory
    private let dialTimeout: TimeInterval
    /// this device dialed the running call; the caller alone publishes its log
    private var isCaller = false

    private var state = CallState() {
        didSet { stateStream.send(state) }
    }
    private var transport: CallMediaTransport?
    private var transportTask: Task<Void, Never>?
    private var dialTimeoutTask: Task<Void, Never>?
    /// remote candidates that arrived while the offer was still ringing
    private var heldRemoteCandidates: [CallSignal.IceCandidate] = []
    /// the incoming offer being rung, kept to answer it
    private var pendingOffer: CallSignalEvent?
    /// locally gathered candidates waiting for their debounce flush
    private var outgoingCandidates: [CallSignal.IceCandidate] = []
    private var candidateFlushTask: Task<Void, Never>?
    /// pending ICE restart after a disconnect; cancelled when media returns
    private var iceRestartTask: Task<Void, Never>?
    /// how long a disconnect may last before the caller restarts ICE
    private let iceRestartDelay: TimeInterval

    public init(ownUserId: String, sendSignal: @escaping SignalSender,
                sendLog: @escaping LogSender = { _, _ in },
                mayCall: @escaping CallGate = { _ in true },
                makeTransport: @escaping TransportFactory,
                dialTimeout: TimeInterval = CallSignal.offerLifetime,
                iceRestartDelay: TimeInterval = 3.0) {
        self.ownUserId = ownUserId
        self.sendSignal = sendSignal
        self.sendLog = sendLog
        self.mayCall = mayCall
        self.makeTransport = makeTransport
        self.dialTimeout = dialTimeout
        self.iceRestartDelay = iceRestartDelay
    }

    /// Wires the manager to a running engine: signals out through it, signals
    /// in from its stream.
    public init(engine: SyncEngine, mayCall: @escaping CallGate = { _ in true },
                makeTransport: @escaping TransportFactory) {
        self.init(ownUserId: engine.ownUserId,
                  sendSignal: { [weak engine] signal, chatId in
                      await engine?.sendCallSignal(signal, chatId: chatId)
                  },
                  sendLog: { [weak engine] log, chatId in
                      await engine?.sendCallLog(log, chatId: chatId)
                  },
                  mayCall: mayCall,
                  makeTransport: makeTransport)
        let signals = engine.callSignalStream.subscribe()
        Task { [weak self] in
            for await event in signals {
                await self?.handle(event)
            }
        }
    }

    public var current: CallState { state }

    // MARK: - User actions

    /// Dials the chat's peer. One call at a time: dialing over a live call is
    /// refused silently, the UI never offers it.
    public func startCall(chatId: String, peerUserId: String) async {
        guard case .idle = state.phase else { return }
        let callId = UUID().uuidString
        isCaller = true
        state = CallState(phase: .dialing, chatId: chatId, peerUserId: peerUserId, callId: callId)
        do {
            let transport = try makeTransport()
            self.transport = transport
            consume(transport)
            let sdp = try await transport.makeOffer()
            // dialing may have been torn down while the offer was being built
            guard state.callId == callId, state.phase == .dialing else { return }
            await sendSignal(CallSignal(type: .offer, callId: callId, sdp: sdp), chatId)
            armDialTimeout(callId: callId)
        } catch {
            await finish(reason: .failed, notifyPeer: false)
        }
    }

    /// Answers the ringing call.
    public func accept() async {
        guard state.phase == .ringing, let offer = pendingOffer,
              let sdp = offer.signal.sdp else { return }
        state.phase = .connecting
        do {
            let transport = try makeTransport()
            self.transport = transport
            consume(transport)
            let answer = try await transport.answerOffer(sdp)
            guard state.callId == offer.signal.callId else { return }
            if !heldRemoteCandidates.isEmpty {
                await transport.add(candidates: heldRemoteCandidates)
                heldRemoteCandidates = []
            }
            await sendSignal(CallSignal(type: .answer, callId: offer.signal.callId, sdp: answer),
                             offer.chatId)
        } catch {
            await finish(reason: .failed, notifyPeer: true)
        }
    }

    /// Refuses the ringing call.
    public func decline() async {
        guard state.phase == .ringing, let chatId = state.chatId, let callId = state.callId else { return }
        await sendSignal(CallSignal(type: .end, callId: callId, reason: .decline), chatId)
        await teardown(showing: .ended(.decline))
    }

    /// Ends the call from this side: cancels a dial, hangs up a live call.
    public func hangUp() async {
        guard let chatId = state.chatId, let callId = state.callId else { return }
        let reason: CallSignal.EndReason = state.phase == .dialing ? .cancel : .hangup
        await sendSignal(CallSignal(type: .end, callId: callId, reason: reason), chatId)
        await teardown(showing: .ended(reason))
    }

    public func setMuted(_ muted: Bool) async {
        state.muted = muted
        await transport?.setMuted(muted)
    }

    /// The UI dismisses the ended-call screen.
    public func reset() {
        guard case .ended = state.phase else { return }
        state = CallState()
    }

    // MARK: - Incoming signals

    public func handle(_ event: CallSignalEvent) async {
        // own echo from another of this account's devices: the call was picked
        // up or refused there, so this device stops ringing
        if event.fromUserId == ownUserId {
            if state.phase == .ringing, event.signal.callId == state.callId,
               event.signal.type == .answer || event.signal.type == .end {
                await teardown(showing: CallState())
            }
            return
        }
        switch event.signal.type {
        case .offer:
            await handleOffer(event)
        case .answer:
            guard event.signal.callId == state.callId,
                  let sdp = event.signal.sdp, let transport else { return }
            switch state.phase {
            case .dialing:
                dialTimeoutTask?.cancel()
                state.phase = .connecting
                do {
                    try await transport.acceptAnswer(sdp)
                } catch {
                    await finish(reason: .failed, notifyPeer: true)
                }
            case .active, .connecting:
                // the answer to an ICE-restart offer; the call stays up
                do {
                    try await transport.acceptAnswer(sdp)
                } catch {
                    await finish(reason: .failed, notifyPeer: true)
                }
            default:
                return
            }
        case .ice:
            guard event.signal.callId == state.callId,
                  let candidates = event.signal.candidates, !candidates.isEmpty else { return }
            if let transport {
                await transport.add(candidates: candidates)
            } else {
                heldRemoteCandidates.append(contentsOf: candidates)
            }
        case .end:
            guard event.signal.callId == state.callId else { return }
            await teardown(showing: .ended(event.signal.reason ?? .hangup))
        }
    }

    private func handleOffer(_ event: CallSignalEvent) async {
        // a fresh offer for the running call is the caller restarting ICE
        // after a network change: answer it on the live transport, in place
        if event.signal.callId == state.callId,
           state.phase == .active || state.phase == .connecting,
           let sdp = event.signal.sdp, let transport,
           let chatId = state.chatId, let callId = state.callId {
            if let answer = try? await transport.answerOffer(sdp) {
                await sendSignal(CallSignal(type: .answer, callId: callId, sdp: answer), chatId)
            }
            return
        }
        // glare: both sides dialed the same chat. The smaller call id survives
        // as the call and its side ignores the other offer; the larger side
        // cancels its own dial and answers the survivor.
        if state.phase == .dialing, state.chatId == event.chatId,
           let myCallId = state.callId, let chatId = state.chatId {
            if myCallId < event.signal.callId { return }
            await sendSignal(CallSignal(type: .end, callId: myCallId, reason: .cancel), chatId)
            await teardown(showing: CallState())
            pendingOffer = event
            isCaller = false
            state = CallState(phase: .ringing, chatId: event.chatId,
                              peerUserId: event.fromUserId, callId: event.signal.callId)
            await accept()
            return
        }
        // one call at a time: a second offer is answered busy, wherever from
        guard case .idle = state.phase else {
            if event.signal.callId != state.callId {
                await sendSignal(CallSignal(type: .end, callId: event.signal.callId, reason: .busy),
                                 event.chatId)
            }
            return
        }
        // the callee's own privacy: an offer from someone the setting shuts
        // out is answered busy — the same answer as being on another call, so
        // the caller learns nothing — and this device never rings. Judged
        // here because the signaling is E2EE and no server sees the offer.
        guard await mayCall(event.fromUserId) else {
            await sendSignal(CallSignal(type: .end, callId: event.signal.callId, reason: .busy),
                             event.chatId)
            return
        }
        // a call may have started while the gate was being judged
        guard case .idle = state.phase else {
            if event.signal.callId != state.callId {
                await sendSignal(CallSignal(type: .end, callId: event.signal.callId, reason: .busy),
                                 event.chatId)
            }
            return
        }
        pendingOffer = event
        heldRemoteCandidates = []
        isCaller = false
        state = CallState(phase: .ringing, chatId: event.chatId,
                          peerUserId: event.fromUserId, callId: event.signal.callId)
    }

    // MARK: - Transport events

    private func consume(_ transport: CallMediaTransport) {
        let events = transport.events()
        transportTask = Task { [weak self] in
            for await event in events {
                await self?.handleTransport(event)
            }
        }
    }

    private func handleTransport(_ event: CallTransportEvent) async {
        switch event {
        case .candidates(let list):
            outgoingCandidates.append(contentsOf: list)
            scheduleCandidateFlush()
        case .connected:
            iceRestartTask?.cancel()
            iceRestartTask = nil
            guard state.phase == .connecting || state.phase == .active else { return }
            if state.phase != .active {
                state.phase = .active
                state.connectedAt = Date().timeIntervalSince1970
            }
        case .disconnected:
            // the transport keeps trying on its own; a disconnect that
            // outlives the delay (a Wi-Fi to LTE move) gets an ICE restart
            // from the caller — one side only, or the offers would glare
            scheduleIceRestart()
        case .failed:
            await finish(reason: .failed, notifyPeer: true)
        }
    }

    private func scheduleIceRestart() {
        guard isCaller, iceRestartTask == nil, state.phase == .active else { return }
        let callId = state.callId
        iceRestartTask = Task { [weak self, iceRestartDelay] in
            try? await Task.sleep(nanoseconds: UInt64(iceRestartDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.restartIce(callId: callId)
        }
    }

    private func restartIce(callId: String?) async {
        iceRestartTask = nil
        guard isCaller, state.phase == .active, state.callId == callId,
              let chatId = state.chatId, let callId, let transport else { return }
        do {
            let sdp = try await transport.restartOffer()
            guard state.callId == callId else { return }
            await sendSignal(CallSignal(type: .offer, callId: callId, sdp: sdp), chatId)
        } catch {
            await finish(reason: .failed, notifyPeer: true)
        }
    }

    /// Candidates arrive one by one and are worth a frame only in batches.
    private func scheduleCandidateFlush() {
        guard candidateFlushTask == nil else { return }
        candidateFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            await self?.flushCandidates()
        }
    }

    private func flushCandidates() async {
        candidateFlushTask = nil
        guard !outgoingCandidates.isEmpty,
              let chatId = state.chatId, let callId = state.callId else {
            outgoingCandidates = []
            return
        }
        let batch = outgoingCandidates
        outgoingCandidates = []
        await sendSignal(CallSignal(type: .ice, callId: callId, candidates: batch), chatId)
    }

    // MARK: - Teardown

    private func armDialTimeout(callId: String) {
        dialTimeoutTask?.cancel()
        let timeout = dialTimeout
        dialTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.dialTimedOut(callId: callId)
        }
    }

    private func dialTimedOut(callId: String) async {
        guard state.phase == .dialing, state.callId == callId else { return }
        await finish(reason: .timeout, notifyPeer: true)
    }

    private func finish(reason: CallSignal.EndReason, notifyPeer: Bool) async {
        if notifyPeer, let chatId = state.chatId, let callId = state.callId {
            await sendSignal(CallSignal(type: .end, callId: callId, reason: reason), chatId)
        }
        await teardown(showing: .ended(reason))
    }

    private func teardown(showing phase: CallPhase) async {
        if case .ended(let reason) = phase { await publishLog(reason: reason) }
        var next = state
        next.phase = phase
        next.muted = false
        await teardown(showing: next)
    }

    /// The caller alone writes the call into the feed, once the outcome is
    /// known: how it ended, and for a completed call how long it ran.
    private func publishLog(reason: CallSignal.EndReason) async {
        guard isCaller, let chatId = state.chatId, let callId = state.callId else { return }
        let outcome: CallLog.Outcome
        var duration: Double?
        if let connectedAt = state.connectedAt {
            outcome = .completed
            duration = max(0, Date().timeIntervalSince1970 - connectedAt)
        } else {
            switch reason {
            case .decline: outcome = .declined
            case .busy: outcome = .busy
            case .failed: outcome = .failed
            case .hangup, .cancel, .timeout: outcome = .missed
            }
        }
        await sendLog(CallLog(outcome: outcome, duration: duration, callId: callId), chatId)
    }

    private func teardown(showing next: CallState) async {
        dialTimeoutTask?.cancel()
        dialTimeoutTask = nil
        candidateFlushTask?.cancel()
        candidateFlushTask = nil
        iceRestartTask?.cancel()
        iceRestartTask = nil
        transportTask?.cancel()
        transportTask = nil
        outgoingCandidates = []
        heldRemoteCandidates = []
        pendingOffer = nil
        if let transport {
            self.transport = nil
            await transport.close()
        }
        state = next
    }
}
