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
    /// the peer started (or stopped) sending video
    case remoteVideo(Bool)
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
    /// turns the local camera on or off; adding the track the first time
    /// changes the SDP, so the manager follows up with a renegotiation offer
    func setVideo(enabled: Bool) async
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
    /// this side's camera is sending
    public var localVideo = false
    /// the peer's camera is sending
    public var remoteVideo = false
    /// extra participants of a conference, beyond `peerUserId`, join order
    public var extraPeers: [String] = []
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
    /// Opens (or finds) the direct chat with a user and returns its id: the
    /// signaling channel to a conference participant one has never written to.
    public typealias ChatOpener = @Sendable (_ userId: String) async -> String?

    /// One extra participant of a conference: their own transport and the
    /// direct chat their signaling rides.
    private final class PeerLink {
        let userId: String
        let chatId: String
        let transport: CallMediaTransport
        var task: Task<Void, Never>?
        var outgoing: [CallSignal.IceCandidate] = []
        var flushTask: Task<Void, Never>?

        init(userId: String, chatId: String, transport: CallMediaTransport) {
            self.userId = userId
            self.chatId = chatId
            self.transport = transport
        }
    }

    public nonisolated let stateStream = Broadcast<CallState>(initial: CallState())

    private let ownUserId: String
    private let sendSignal: SignalSender
    private let sendLog: LogSender
    private let mayCall: CallGate
    private let makeTransport: TransportFactory
    private let openChat: ChatOpener
    private let sendInviteRow: @Sendable (_ chatId: String, _ invitedUserId: String) async -> Void
    private let dialTimeout: TimeInterval
    /// conference links beyond the primary peer, by userId
    private var extras: [String: PeerLink] = [:]
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
    /// candidates that outran their offer: they ride the ephemeral relay and
    /// the offer rides the journal, so the order between them is not given.
    /// Keyed by callId, claimed when the offer lands, capped small.
    private var earlyCandidates: [String: [CallSignal.IceCandidate]] = [:]
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
                openChat: @escaping ChatOpener = { _ in nil },
                sendInviteRow: @Sendable @escaping (String, String) async -> Void = { _, _ in },
                dialTimeout: TimeInterval = CallSignal.offerLifetime,
                iceRestartDelay: TimeInterval = 3.0) {
        self.ownUserId = ownUserId
        self.sendSignal = sendSignal
        self.sendLog = sendLog
        self.mayCall = mayCall
        self.makeTransport = makeTransport
        self.openChat = openChat
        self.sendInviteRow = sendInviteRow
        self.dialTimeout = dialTimeout
        self.iceRestartDelay = iceRestartDelay
    }

    /// Wires the manager to a running engine: signals out through it, signals
    /// in from its stream.
    public init(engine: SyncEngine, mayCall: @escaping CallGate = { _ in true },
                makeTransport: @escaping TransportFactory,
                openChat: @escaping ChatOpener = { _ in nil }) {
        self.init(ownUserId: engine.ownUserId,
                  sendSignal: { [weak engine] signal, chatId in
                      await engine?.sendCallSignal(signal, chatId: chatId)
                  },
                  sendLog: { [weak engine] log, chatId in
                      await engine?.sendCallLog(log, chatId: chatId)
                  },
                  mayCall: mayCall,
                  makeTransport: makeTransport,
                  openChat: openChat,
                  sendInviteRow: { [weak engine] chatId, invitedUserId in
                      await engine?.sendCallInviteRow(chatId: chatId, invitedUserId: invitedUserId)
                  })
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
            // an offer into a conference names everyone already in it: the
            // joiner dials each of the others over their direct chats
            if let members = offer.signal.members {
                for member in members where member != ownUserId && member != offer.fromUserId {
                    await dialLink(to: member, callId: offer.signal.callId)
                }
            }
        } catch {
            await finish(reason: .failed, notifyPeer: true)
        }
    }

    /// Pulls a third person into the running call: their leg is its own
    /// transport over the direct chat, and the chat gets the invited-by row.
    public func invite(userId: String) async {
        guard state.phase == .active, let callId = state.callId,
              userId != ownUserId, userId != state.peerUserId,
              extras[userId] == nil, extras.count < 2 else { return }
        var everyone = [ownUserId]
        if let primary = state.peerUserId { everyone.append(primary) }
        everyone.append(contentsOf: extras.keys)
        guard let chatId = await openChat(userId), state.callId == callId else { return }
        do {
            let transport = try makeTransport()
            let link = PeerLink(userId: userId, chatId: chatId, transport: transport)
            extras[userId] = link
            state.extraPeers.append(userId)
            consumeLink(link)
            let sdp = try await transport.makeOffer()
            guard state.callId == callId else { return }
            await sendSignal(CallSignal(type: .offer, callId: callId, sdp: sdp,
                                        members: everyone), chatId)
            await sendInviteRow(chatId, userId)
        } catch {
            await closeLink(userId)
        }
    }

    /// The joiner's leg toward one existing participant: an offer over their
    /// direct chat, carrying the callId that proves membership.
    private func dialLink(to userId: String, callId: String) async {
        guard extras[userId] == nil, userId != state.peerUserId else { return }
        guard let chatId = await openChat(userId), state.callId == callId else { return }
        do {
            let transport = try makeTransport()
            let link = PeerLink(userId: userId, chatId: chatId, transport: transport)
            extras[userId] = link
            state.extraPeers.append(userId)
            consumeLink(link)
            let sdp = try await transport.makeOffer()
            guard state.callId == callId else { return }
            await sendSignal(CallSignal(type: .offer, callId: callId, sdp: sdp), chatId)
        } catch {
            await closeLink(userId)
        }
    }

    /// An offer for the running call from someone new: the conference leg
    /// reaching this side. The callId is the ticket, so it joins in place.
    private func acceptLink(_ event: CallSignalEvent, sdp: String, callId: String) async {
        do {
            let transport = try makeTransport()
            let link = PeerLink(userId: event.fromUserId, chatId: event.chatId,
                                transport: transport)
            extras[event.fromUserId] = link
            state.extraPeers.append(event.fromUserId)
            consumeLink(link)
            let answer = try await transport.answerOffer(sdp)
            guard state.callId == callId else { return }
            if let early = earlyCandidates.removeValue(forKey: callId) {
                await transport.add(candidates: early)
            }
            await sendSignal(CallSignal(type: .answer, callId: callId, sdp: answer), event.chatId)
        } catch {
            await closeLink(event.fromUserId)
        }
    }

    private func consumeLink(_ link: PeerLink) {
        let events = link.transport.events()
        let userId = link.userId
        link.task = Task { [weak self] in
            for await event in events {
                await self?.handleLinkTransport(event, userId: userId)
            }
        }
    }

    private func handleLinkTransport(_ event: CallTransportEvent, userId: String) async {
        guard let link = extras[userId] else { return }
        switch event {
        case .candidates(let list):
            link.outgoing.append(contentsOf: list)
            scheduleLinkFlush(link)
        case .failed:
            // one leg failing drops that participant, not the call
            await closeLink(userId)
        case .connected, .disconnected, .remoteVideo:
            break
        }
    }

    private func scheduleLinkFlush(_ link: PeerLink) {
        guard link.flushTask == nil else { return }
        let userId = link.userId
        link.flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            await self?.flushLinkCandidates(userId: userId)
        }
    }

    private func flushLinkCandidates(userId: String) async {
        guard let link = extras[userId], let callId = state.callId else { return }
        link.flushTask = nil
        guard !link.outgoing.isEmpty else { return }
        let batch = link.outgoing
        link.outgoing = []
        await sendSignal(CallSignal(type: .ice, callId: callId, candidates: batch), link.chatId)
    }

    /// Closes one conference leg and forgets the participant.
    private func closeLink(_ userId: String) async {
        guard let link = extras.removeValue(forKey: userId) else { return }
        link.task?.cancel()
        link.flushTask?.cancel()
        await link.transport.close()
        state.extraPeers.removeAll { $0 == userId }
    }

    /// Refuses the ringing call.
    public func decline() async {
        guard state.phase == .ringing, let chatId = state.chatId, let callId = state.callId else { return }
        await sendSignal(CallSignal(type: .end, callId: callId, reason: .decline), chatId)
        await teardown(showing: .ended(.decline))
    }

    /// Ends the call from this side: cancels a dial, hangs up a live call.
    /// Every leg of a conference is told, over its own chat.
    public func hangUp() async {
        guard let chatId = state.chatId, let callId = state.callId else { return }
        let reason: CallSignal.EndReason = state.phase == .dialing ? .cancel : .hangup
        await sendSignal(CallSignal(type: .end, callId: callId, reason: reason), chatId)
        for link in extras.values {
            await sendSignal(CallSignal(type: .end, callId: callId, reason: reason), link.chatId)
        }
        await teardown(showing: .ended(reason))
    }

    public func setMuted(_ muted: Bool) async {
        state.muted = muted
        await transport?.setMuted(muted)
        for link in extras.values {
            await link.transport.setMuted(muted)
        }
    }

    /// Turns the local camera on or off. The first time a video track joins
    /// the connection the SDP changes, so a renegotiation offer for the same
    /// call follows; the peer answers it on the live transport.
    public func setVideo(_ on: Bool) async {
        // a conference is voice-only for now: renegotiating video across the
        // mesh is not built, and half-applied video would be worse than none
        guard extras.isEmpty else { return }
        guard state.phase == .active || state.phase == .connecting,
              let transport, let chatId = state.chatId, let callId = state.callId else { return }
        await transport.setVideo(enabled: on)
        state.localVideo = on
        if let sdp = try? await transport.makeOffer(), state.callId == callId {
            await sendSignal(CallSignal(type: .offer, callId: callId, sdp: sdp, video: on), chatId)
        }
    }

    /// The transport this call runs on, for the UI to reach media surfaces
    /// (video renderers) the core does not model.
    public func activeTransport() -> CallMediaTransport? { transport }

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
                  let sdp = event.signal.sdp else { return }
            // a conference leg's answer lands on that leg's transport
            if let link = extras[event.fromUserId] {
                try? await link.transport.acceptAnswer(sdp)
                return
            }
            guard let transport else { return }
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
            guard let candidates = event.signal.candidates, !candidates.isEmpty else { return }
            guard event.signal.callId == state.callId else {
                // ahead of its offer: keep it until the offer lands
                if earlyCandidates.count >= 2, earlyCandidates[event.signal.callId] == nil {
                    earlyCandidates = [:]
                }
                earlyCandidates[event.signal.callId, default: []].append(contentsOf: candidates)
                return
            }
            if let link = extras[event.fromUserId] {
                await link.transport.add(candidates: candidates)
            } else if event.fromUserId == state.peerUserId, let transport {
                await transport.add(candidates: candidates)
            } else if event.fromUserId == state.peerUserId {
                heldRemoteCandidates.append(contentsOf: candidates)
            } else {
                // a conference leg whose offer has not landed here yet
                earlyCandidates[event.signal.callId, default: []].append(contentsOf: candidates)
            }
        case .end:
            guard event.signal.callId == state.callId else { return }
            // a conference participant leaving takes their leg, not the call
            if extras[event.fromUserId] != nil {
                await closeLink(event.fromUserId)
                return
            }
            guard event.fromUserId == state.peerUserId else { return }
            if let promoted = state.extraPeers.first, let link = extras[promoted] {
                // the primary peer left a conference: the oldest extra leg
                // becomes the call, and the screen keeps standing on it
                extras.removeValue(forKey: promoted)
                transportTask?.cancel()
                await transport?.close()
                transport = link.transport
                link.task?.cancel()
                consume(link.transport)
                state.peerUserId = promoted
                state.chatId = link.chatId
                state.extraPeers.removeAll { $0 == promoted }
                return
            }
            await teardown(showing: .ended(event.signal.reason ?? .hangup))
        }
    }

    private func handleOffer(_ event: CallSignalEvent) async {
        // a fresh offer for the running call from its peer is the caller
        // restarting ICE or renegotiating video: answered in place
        if event.signal.callId == state.callId,
           event.fromUserId == state.peerUserId,
           state.phase == .active || state.phase == .connecting,
           let sdp = event.signal.sdp, let transport,
           let chatId = state.chatId, let callId = state.callId {
            if let answer = try? await transport.answerOffer(sdp) {
                await sendSignal(CallSignal(type: .answer, callId: callId, sdp: answer), chatId)
            }
            // the renegotiation says whether the peer's camera is on: the
            // track going quiet on its own would only freeze the last frame
            if let video = event.signal.video { state.remoteVideo = video }
            return
        }
        // the same for an extra leg of a conference
        if event.signal.callId == state.callId, let link = extras[event.fromUserId],
           let sdp = event.signal.sdp, let callId = state.callId {
            if let answer = try? await link.transport.answerOffer(sdp) {
                await sendSignal(CallSignal(type: .answer, callId: callId, sdp: answer), link.chatId)
            }
            return
        }
        // a same-callId offer from someone new is a conference leg reaching
        // this side: the callId is the ticket, so it joins without ringing
        if event.signal.callId == state.callId,
           state.phase == .active || state.phase == .connecting,
           let sdp = event.signal.sdp, let callId = state.callId,
           extras.count < 2 {
            await acceptLink(event, sdp: sdp, callId: callId)
            return
        }
        // glare: both sides dialed the same chat. The smaller call id survives
        // as the call and its side ignores the other offer; the larger side
        // cancels its own dial and answers the survivor.
        if state.phase == .dialing, state.chatId == event.chatId,
           let myCallId = state.callId, let chatId = state.chatId {
            if myCallId < event.signal.callId { return }
            await sendSignal(CallSignal(type: .end, callId: myCallId, reason: .cancel), chatId)
            // claimed before teardown, which clears the early buffer whole
            let early = earlyCandidates.removeValue(forKey: event.signal.callId) ?? []
            await teardown(showing: CallState())
            pendingOffer = event
            heldRemoteCandidates = early
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
        heldRemoteCandidates = earlyCandidates.removeValue(forKey: event.signal.callId) ?? []
        earlyCandidates = [:]
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
        case .remoteVideo(let on):
            state.remoteVideo = on
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
        next.localVideo = false
        next.remoteVideo = false
        next.extraPeers = []
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
        earlyCandidates = [:]
        pendingOffer = nil
        for userId in Array(extras.keys) {
            await closeLink(userId)
        }
        if let transport {
            self.transport = nil
            await transport.close()
        }
        state = next
    }
}
