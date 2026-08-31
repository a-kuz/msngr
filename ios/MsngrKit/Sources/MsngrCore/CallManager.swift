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

    public nonisolated let stateStream = Broadcast<CallState>(initial: CallState())

    private let ownUserId: String
    private let sendSignal: SignalSender
    private let makeTransport: TransportFactory
    private let dialTimeout: TimeInterval

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

    public init(ownUserId: String, sendSignal: @escaping SignalSender,
                makeTransport: @escaping TransportFactory,
                dialTimeout: TimeInterval = CallSignal.offerLifetime) {
        self.ownUserId = ownUserId
        self.sendSignal = sendSignal
        self.makeTransport = makeTransport
        self.dialTimeout = dialTimeout
    }

    /// Wires the manager to a running engine: signals out through it, signals
    /// in from its stream.
    public init(engine: SyncEngine, makeTransport: @escaping TransportFactory) {
        self.init(ownUserId: engine.ownUserId,
                  sendSignal: { [weak engine] signal, chatId in
                      await engine?.sendCallSignal(signal, chatId: chatId)
                  },
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
            guard event.signal.callId == state.callId, state.phase == .dialing,
                  let sdp = event.signal.sdp, let transport else { return }
            dialTimeoutTask?.cancel()
            state.phase = .connecting
            do {
                try await transport.acceptAnswer(sdp)
            } catch {
                await finish(reason: .failed, notifyPeer: true)
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
        // glare: both sides dialed the same chat. The smaller call id survives
        // as the call and its side ignores the other offer; the larger side
        // cancels its own dial and answers the survivor.
        if state.phase == .dialing, state.chatId == event.chatId,
           let myCallId = state.callId, let chatId = state.chatId {
            if myCallId < event.signal.callId { return }
            await sendSignal(CallSignal(type: .end, callId: myCallId, reason: .cancel), chatId)
            await teardown(showing: CallState())
            pendingOffer = event
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
        pendingOffer = event
        heldRemoteCandidates = []
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
            guard state.phase == .connecting || state.phase == .active else { return }
            if state.phase != .active {
                state.phase = .active
                state.connectedAt = Date().timeIntervalSince1970
            }
        case .disconnected:
            break // the transport keeps trying; the UI keeps the call up
        case .failed:
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
        var next = state
        next.phase = phase
        next.muted = false
        await teardown(showing: next)
    }

    private func teardown(showing next: CallState) async {
        dialTimeoutTask?.cancel()
        dialTimeoutTask = nil
        candidateFlushTask?.cancel()
        candidateFlushTask = nil
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
