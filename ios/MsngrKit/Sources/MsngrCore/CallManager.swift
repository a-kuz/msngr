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

/// The media half of a 1:1 call: SDP, ICE and audio live here. The production
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
    /// silences the call both ways without closing it, for call hold
    func setHeld(_ held: Bool) async
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
    /// the other side of a 1:1 call; in a room, whoever invited this device
    /// (nil for the one who opened it)
    public var peerUserId: String?
    public var callId: String?
    public var muted = false
    /// this side's camera is sending
    public var localVideo = false
    /// the peer's camera is sending
    public var remoteVideo = false
    /// the call runs in a room on the SFU rather than peer to peer
    public var isRoom = false
    /// everyone else in the room, by userId
    public var participants: [CallParticipant] = []
    /// the room's path to the SFU dropped and is being rebuilt
    public var reconnecting = false
    /// someone else is calling while this call stands; the screen offers to
    /// refuse them or to end this call and take theirs
    public var waitingCallerId: String?
    /// another call is parked behind this one, silent on an open transport;
    /// the screen offers to switch back
    public var heldPeerId: String?
    /// the peer put this call on hold; the silence is theirs, not a defect
    public var remoteHold = false
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
/// `CallMediaTransport` for a 1:1 call and behind `CallRoomSession` for a
/// group call in a room on the SFU.
///
/// Glare — both sides dialing the same chat at once — is settled without a
/// human: the call with the smaller id survives as the call, the other side
/// cancels its own offer and answers the surviving one.
public actor CallManager {
    public typealias TransportFactory = @Sendable () throws -> CallMediaTransport
    public typealias RoomFactory = @Sendable () throws -> CallRoomSession
    /// Fetches the ticket into a call's room, judged by the server against
    /// this user's membership of the chat the call belongs to.
    public typealias TicketFetcher = @Sendable (_ callId: String, _ chatId: String) async throws -> CallRoomTicket
    public typealias SignalSender = @Sendable (CallSignal, String) async -> Void
    public typealias LogSender = @Sendable (CallLog, String) async -> Void
    /// Whether this user's call-privacy setting lets `userId` ring this
    /// device. Judged on the callee: the signaling is E2EE, so no server can.
    public typealias CallGate = @Sendable (_ userId: String) async -> Bool
    /// Opens (or finds) the direct chat with a user and returns its id: the
    /// signaling channel to someone one has never written to.
    public typealias ChatOpener = @Sendable (_ userId: String) async -> String?

    public enum RoomError: Error {
        case unavailable
    }

    public nonisolated let stateStream = Broadcast<CallState>(initial: CallState())

    private let ownUserId: String
    private let sendSignal: SignalSender
    private let sendLog: LogSender
    private let mayCall: CallGate
    private let makeTransport: TransportFactory
    private let makeRoom: RoomFactory
    private let fetchTicket: TicketFetcher
    private let openChat: ChatOpener
    private let sendInviteRow: @Sendable (_ chatId: String, _ invitedUserId: String) async -> Void
    /// Writes or updates the call's card in a chat.
    private let sendLiveCard: @Sendable (CallLive, _ chatId: String) async -> Void
    /// Closes this device's copies of a call's cards once its own call is over.
    private let endLiveCards: @Sendable (_ callId: String) async -> Void
    /// The chats holding this call's card as this device knows them: the one
    /// the call started in, and the chat of everyone this device invited.
    private var liveCardChats: Set<String> = []
    private let dialTimeout: TimeInterval
    /// this device dialed the running call; the caller alone publishes its log
    private var isCaller = false

    private var state = CallState() {
        didSet { stateStream.send(state) }
    }
    private var transport: CallMediaTransport?
    private var transportTask: Task<Void, Never>?
    /// the room of a group call, and the key its frames are encrypted with
    private var room: CallRoomSession?
    private var roomTask: Task<Void, Never>?
    private var roomKey: String?
    private var dialTimeoutTask: Task<Void, Never>?
    /// a room with nobody else in it ends after this long: whoever tapped a
    /// card of a call that died with its last participant's app is not left
    /// standing in an empty room, and that card gets closed
    private let emptyRoomTimeout: TimeInterval
    private var emptyRoomTask: Task<Void, Never>?
    /// remote candidates that arrived while the offer was still ringing
    private var heldRemoteCandidates: [CallSignal.IceCandidate] = []
    /// candidates that outran their offer: they ride the ephemeral relay and
    /// the offer rides the journal, so the order between them is not given.
    /// Keyed by callId, claimed when the offer lands, capped small.
    private var earlyCandidates: [String: [CallSignal.IceCandidate]] = [:]
    /// the incoming offer or room invite being rung, kept to answer it
    private var pendingOffer: CallSignalEvent?
    /// a second caller's offer, waiting behind the live call until the user
    /// refuses it or trades the call for it
    private var waitingOffer: CallSignalEvent?
    /// The call put aside for another one: its transport stays open and
    /// silent until the user switches back or one of the calls ends.
    private struct HeldCall {
        let chatId: String
        let peerUserId: String
        let callId: String
        let transport: CallMediaTransport
        var task: Task<Void, Never>?
        let connectedAt: Double?
        let isCaller: Bool
        let localVideo: Bool
        let remoteVideo: Bool
        var remoteHold: Bool
    }
    private var heldCall: HeldCall?
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
                makeRoom: @escaping RoomFactory = { throw RoomError.unavailable },
                fetchTicket: @escaping TicketFetcher = { _, _ in throw RoomError.unavailable },
                openChat: @escaping ChatOpener = { _ in nil },
                sendInviteRow: @Sendable @escaping (String, String) async -> Void = { _, _ in },
                sendLiveCard: @Sendable @escaping (CallLive, String) async -> Void = { _, _ in },
                endLiveCards: @Sendable @escaping (String) async -> Void = { _ in },
                dialTimeout: TimeInterval = CallSignal.offerLifetime,
                iceRestartDelay: TimeInterval = 3.0,
                emptyRoomTimeout: TimeInterval = 20) {
        self.ownUserId = ownUserId
        self.emptyRoomTimeout = emptyRoomTimeout
        self.sendSignal = sendSignal
        self.sendLog = sendLog
        self.mayCall = mayCall
        self.makeTransport = makeTransport
        self.makeRoom = makeRoom
        self.fetchTicket = fetchTicket
        self.openChat = openChat
        self.sendInviteRow = sendInviteRow
        self.sendLiveCard = sendLiveCard
        self.endLiveCards = endLiveCards
        self.dialTimeout = dialTimeout
        self.iceRestartDelay = iceRestartDelay
    }

    /// Wires the manager to a running engine: signals out through it, signals
    /// in from its stream.
    public init(engine: SyncEngine, mayCall: @escaping CallGate = { _ in true },
                makeTransport: @escaping TransportFactory,
                makeRoom: @escaping RoomFactory = { throw RoomError.unavailable },
                fetchTicket: @escaping TicketFetcher = { _, _ in throw RoomError.unavailable },
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
                  makeRoom: makeRoom,
                  fetchTicket: fetchTicket,
                  openChat: openChat,
                  sendInviteRow: { [weak engine] chatId, invitedUserId in
                      await engine?.sendCallInviteRow(chatId: chatId, invitedUserId: invitedUserId)
                  },
                  sendLiveCard: { [weak engine] card, chatId in
                      await engine?.sendCallLive(card, chatId: chatId)
                  },
                  endLiveCards: { [weak engine] callId in
                      await engine?.closeCallLiveLocally(callId: callId)
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
    /// refused silently, the UI never offers it. A video call starts with the
    /// camera already in the offer, and the offer says so for the ringing
    /// screen.
    public func startCall(chatId: String, peerUserId: String, video: Bool = false) async {
        guard case .idle = state.phase else { return }
        let callId = UUID().uuidString
        isCaller = true
        state = CallState(phase: .dialing, chatId: chatId, peerUserId: peerUserId, callId: callId)
        do {
            let transport = try makeTransport()
            self.transport = transport
            consume(transport)
            if video {
                await transport.setVideo(enabled: true)
                state.localVideo = true
            }
            let sdp = try await transport.makeOffer()
            // dialing may have been torn down while the offer was being built
            guard state.callId == callId, state.phase == .dialing else { return }
            await sendSignal(CallSignal(type: .offer, callId: callId, sdp: sdp,
                                        video: video ? true : nil), chatId)
            armDialTimeout(callId: callId)
        } catch {
            await finish(reason: .failed, notifyPeer: false)
        }
    }

    /// Opens a room for the chat — a group's call — and invites everyone in
    /// it: this device joins first, the `room` invite rings the members, and
    /// the card lands in the chat for whoever comes later. Dialing until the
    /// first person joins; nobody within the dial timeout is «no answer».
    public func startGroupCall(chatId: String, video: Bool = false) async {
        guard case .idle = state.phase else { return }
        let callId = UUID().uuidString
        let key = CallRoomKey.make()
        isCaller = true
        state = CallState(phase: .dialing, chatId: chatId, callId: callId)
        state.isRoom = true
        state.localVideo = video
        roomKey = key
        do {
            try await openRoom(callId: callId, chatId: chatId, key: key, video: video)
            guard state.callId == callId, state.phase == .dialing else { return }
            await sendSignal(CallSignal(type: .room, callId: callId,
                                        video: video ? true : nil, key: key), chatId)
            liveCardChats.insert(chatId)
            await refreshLiveCards()
            armDialTimeout(callId: callId)
        } catch {
            await finish(reason: .failed, notifyPeer: false)
        }
    }

    /// Answers the ringing call: a 1:1 offer with an answer over signaling, a
    /// room invite by joining the room.
    public func accept() async {
        guard state.phase == .ringing, let offer = pendingOffer else { return }
        if offer.signal.type == .room {
            await acceptRoom(offer)
            return
        }
        guard let sdp = offer.signal.sdp else { return }
        state.phase = .connecting
        do {
            let transport = try makeTransport()
            self.transport = transport
            consume(transport)
            // a video call is answered with the camera on, so the answer
            // already carries the track back
            if offer.signal.video == true {
                await transport.setVideo(enabled: true)
                state.localVideo = true
            }
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

    /// The room invite is accepted by walking in: a ticket from the server,
    /// the room joined under the invite's key. The bare answer on the wire
    /// is for this account's other devices, which stop ringing on it.
    private func acceptRoom(_ offer: CallSignalEvent) async {
        guard let key = offer.signal.key else {
            await finish(reason: .failed, notifyPeer: false)
            return
        }
        let callId = offer.signal.callId
        state.phase = .connecting
        state.localVideo = offer.signal.video == true
        roomKey = key
        await sendSignal(CallSignal(type: .answer, callId: callId), offer.chatId)
        do {
            try await openRoom(callId: callId, chatId: offer.chatId, key: key,
                               video: offer.signal.video == true)
            guard state.callId == callId, state.phase == .connecting else { return }
            state.phase = .active
            state.connectedAt = Date().timeIntervalSince1970
            liveCardChats.insert(offer.chatId)
        } catch {
            await finish(reason: .failed, notifyPeer: false)
        }
    }

    /// Fetches the ticket and joins the room; the session's events run from
    /// here on. Throws when the server refuses or the room will not take us.
    private func openRoom(callId: String, chatId: String, key: String, video: Bool) async throws {
        do {
            let ticket = try await fetchTicket(callId, chatId)
            guard state.callId == callId else { return }
            let room = try makeRoom()
            self.room = room
            consumeRoom(room)
            try await room.join(url: ticket.url, token: ticket.token, key: key, video: video)
            await room.setMuted(state.muted)
        } catch {
            MsngrLog.call.error("room join failed call=\(callId, privacy: .public) error=\(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Pulls another person into the running call. A 1:1 call first moves
    /// into a room — this device opens one and hands the peer the key over
    /// their chat, so the peer joins in place — and then the invite goes to
    /// the new person over their direct chat, with the invited-by row and
    /// the card. A room has no cap on this side: the SFU's is the ceiling.
    public func invite(userId: String) async {
        guard state.phase == .active, let callId = state.callId,
              userId != ownUserId, userId != state.peerUserId,
              !state.participants.contains(where: { $0.userId == userId }) else { return }
        if !state.isRoom {
            guard await upgradeToRoom() else { return }
            guard state.callId == callId else { return }
        }
        guard let key = roomKey else { return }
        guard let chatId = await openChat(userId), state.callId == callId else { return }
        await sendSignal(CallSignal(type: .room, callId: callId, key: key), chatId)
        await sendInviteRow(chatId, userId)
        // the card goes into the chat the call started in and into the
        // invited person's chat
        if let primary = state.chatId { liveCardChats.insert(primary) }
        liveCardChats.insert(chatId)
        await refreshLiveCards()
    }

    /// The 1:1 call becomes a room call in place: the peer learns the key
    /// over the chat before the peer-to-peer transport closes, then this
    /// device joins the room. The moment of silence between the two is the
    /// price of running one WebRTC audio unit at a time.
    private func upgradeToRoom() async -> Bool {
        guard state.phase == .active, let callId = state.callId, let chatId = state.chatId,
              transport != nil else { return false }
        let key = CallRoomKey.make()
        roomKey = key
        await sendSignal(CallSignal(type: .room, callId: callId,
                                    video: state.localVideo ? true : nil, key: key), chatId)
        await closeTransport()
        state.isRoom = true
        state.remoteVideo = false
        state.remoteHold = false
        do {
            try await openRoom(callId: callId, chatId: chatId, key: key, video: state.localVideo)
            guard state.callId == callId else { return false }
            liveCardChats.insert(chatId)
            return true
        } catch {
            await finish(reason: .failed, notifyPeer: true)
            return false
        }
    }

    /// The peer moved the running call into a room: this side follows —
    /// the transport closes, the room is joined under the peer's key — and
    /// the call stands throughout.
    private func followIntoRoom(_ event: CallSignalEvent) async {
        guard let key = event.signal.key, let callId = state.callId, let chatId = state.chatId else { return }
        roomKey = key
        await closeTransport()
        state.isRoom = true
        state.remoteVideo = false
        state.remoteHold = false
        do {
            try await openRoom(callId: callId, chatId: chatId, key: key, video: state.localVideo)
            guard state.callId == callId else { return }
            liveCardChats.insert(chatId)
        } catch {
            await finish(reason: .failed, notifyPeer: true)
        }
    }

    /// Joins the running call a live card describes: a ticket for the chat
    /// the card is in, the room under the card's key. A card with no key
    /// belongs to a call this build cannot join.
    public func join(_ card: CallLive, chatId: String, hostUserId: String) async {
        guard case .idle = state.phase, card.isLive, let key = card.key else { return }
        isCaller = false
        state = CallState(phase: .connecting, chatId: chatId,
                          peerUserId: hostUserId == ownUserId ? nil : hostUserId, callId: card.callId)
        state.isRoom = true
        roomKey = key
        do {
            try await openRoom(callId: card.callId, chatId: chatId, key: key, video: false)
            guard state.callId == card.callId, state.phase == .connecting else { return }
            state.phase = .active
            state.connectedAt = Date().timeIntervalSince1970
            liveCardChats.insert(chatId)
        } catch {
            await finish(reason: .failed, notifyPeer: false)
        }
    }

    /// Everyone in the call as this device sees it, sorted so every device
    /// writes the same card.
    private var liveMembers: [String] {
        ([ownUserId] + state.participants.map(\.userId)).sorted()
    }

    /// The one device that keeps the card current while people come and go:
    /// the lowest userId in the room. Every device sees the same roster, so
    /// they agree without a word, and the role passes on when the writer
    /// leaves.
    private var isCardWriter: Bool { liveMembers.first == ownUserId }

    /// Brings the card in every chat this device knows up to date; `endedAt`
    /// closes them and forgets the chats, so nothing is written after the call.
    private func refreshLiveCards(endedAt: Double? = nil, members: [String]? = nil) async {
        guard !liveCardChats.isEmpty, let callId = state.callId else { return }
        let card = CallLive(callId: callId,
                            startedAt: state.connectedAt ?? Date().timeIntervalSince1970,
                            members: (members ?? liveMembers).map { CallLive.Member(id: $0, name: "") },
                            endedAt: endedAt, key: roomKey)
        let chats = liveCardChats
        if endedAt != nil { liveCardChats = [] }
        for chatId in chats {
            await sendLiveCard(card, chatId)
        }
    }

    /// Refuses the ringing call.
    public func decline() async {
        guard state.phase == .ringing, let chatId = state.chatId, let callId = state.callId else { return }
        await sendSignal(CallSignal(type: .end, callId: callId, reason: .decline), chatId)
        await teardown(showing: .ended(.decline))
    }

    /// Ends the call from this side: cancels a dial, hangs up a live call,
    /// leaves a room. A room's opener who is still alone in it cancels the
    /// ringing on everyone's phones; a room with others in it lives on.
    public func hangUp() async {
        guard let chatId = state.chatId, let callId = state.callId else { return }
        let reason: CallSignal.EndReason = state.phase == .dialing ? .cancel : .hangup
        if !state.isRoom || state.phase == .dialing {
            await sendSignal(CallSignal(type: .end, callId: callId, reason: reason), chatId)
        }
        await teardown(showing: .ended(reason))
    }

    /// Refuses the caller waiting behind the live call. They hear busy — the
    /// same answer a call in progress gives with nobody asked — so refusing
    /// tells them nothing being on the phone did not.
    public func declineWaiting() async {
        guard let waiting = waitingOffer else { return }
        waitingOffer = nil
        state.waitingCallerId = nil
        await sendSignal(CallSignal(type: .end, callId: waiting.signal.callId, reason: .busy),
                         waiting.chatId)
    }

    /// Ends the live call and answers the one waiting behind it.
    public func acceptWaiting() async {
        guard waitingOffer != nil else { return }
        if let chatId = state.chatId, let callId = state.callId, !state.isRoom {
            await sendSignal(CallSignal(type: .end, callId: callId, reason: .hangup), chatId)
        }
        // teardown promotes the waiter to ringing on its own
        await teardown(showing: .ended(.hangup))
        await accept()
    }

    /// Puts the live call aside and answers the one waiting behind it: the
    /// held call's transport stays open and silent until the user switches
    /// back or one of the calls ends. With the hold slot already taken, or
    /// on a room call, the trade is the only move left.
    public func holdAndAcceptWaiting() async {
        guard let waiting = waitingOffer, heldCall == nil, !state.isRoom,
              state.phase == .active, let transport,
              let chatId = state.chatId, let callId = state.callId,
              let peerUserId = state.peerUserId else { return }
        waitingOffer = nil
        state.waitingCallerId = nil
        await parkCurrent(transport: transport, chatId: chatId, callId: callId,
                          peerUserId: peerUserId)
        // the waiter rings in place of the parked call and is answered at once
        pendingOffer = waiting
        heldRemoteCandidates = earlyCandidates.removeValue(forKey: waiting.signal.callId) ?? []
        isCaller = false
        state = CallState(phase: .ringing, chatId: waiting.chatId,
                          peerUserId: waiting.fromUserId, callId: waiting.signal.callId)
        state.remoteVideo = waiting.signal.video == true
        state.heldPeerId = peerUserId
        await accept()
    }

    /// Swaps the live call and the held one.
    public func switchToHeld() async {
        guard let held = heldCall, state.phase == .active, !state.isRoom,
              let transport, let chatId = state.chatId, let callId = state.callId,
              let peerUserId = state.peerUserId else { return }
        heldCall = nil
        await parkCurrent(transport: transport, chatId: chatId, callId: callId,
                          peerUserId: peerUserId)
        await unpark(held)
    }

    /// The live call goes onto the hold slot: silent both ways, transport
    /// open, the peer told.
    private func parkCurrent(transport: CallMediaTransport, chatId: String,
                             callId: String, peerUserId: String) async {
        transportTask?.cancel()
        transportTask = nil
        candidateFlushTask?.cancel()
        candidateFlushTask = nil
        outgoingCandidates = []
        iceRestartTask?.cancel()
        iceRestartTask = nil
        await transport.setHeld(true)
        await sendSignal(CallSignal(type: .hold, callId: callId, held: true), chatId)
        var held = HeldCall(chatId: chatId, peerUserId: peerUserId, callId: callId,
                            transport: transport, task: nil,
                            connectedAt: state.connectedAt, isCaller: isCaller,
                            localVideo: state.localVideo, remoteVideo: state.remoteVideo,
                            remoteHold: state.remoteHold)
        held.task = watchHeld(transport, callId: callId)
        heldCall = held
        self.transport = nil
        state.heldPeerId = peerUserId
    }

    /// The held call becomes the call again.
    private func unpark(_ held: HeldCall) async {
        held.task?.cancel()
        await held.transport.setHeld(false)
        await held.transport.setMuted(state.muted)
        transport = held.transport
        consume(held.transport)
        isCaller = held.isCaller
        state.chatId = held.chatId
        state.peerUserId = held.peerUserId
        state.callId = held.callId
        state.connectedAt = held.connectedAt
        state.localVideo = held.localVideo
        state.remoteVideo = held.remoteVideo
        state.remoteHold = held.remoteHold
        state.isRoom = false
        state.participants = []
        state.phase = .active
        await sendSignal(CallSignal(type: .hold, callId: held.callId, held: false), held.chatId)
    }

    /// While a call is parked, only its death matters; everything else waits
    /// for the switch back.
    private func watchHeld(_ transport: CallMediaTransport, callId: String) -> Task<Void, Never> {
        let events = transport.events()
        return Task { [weak self] in
            for await event in events {
                if case .failed = event {
                    await self?.heldFailed(callId: callId)
                    return
                }
            }
        }
    }

    private func heldFailed(callId: String) async {
        guard let held = heldCall, held.callId == callId else { return }
        await dropHeld(held)
    }

    /// Forgets the held call: the transport closes, and the caller's side
    /// still owes the feed its log — the call was live before it was parked,
    /// so it completed.
    private func dropHeld(_ held: HeldCall) async {
        heldCall = nil
        state.heldPeerId = nil
        held.task?.cancel()
        await held.transport.close()
        guard held.isCaller else { return }
        let duration = held.connectedAt.map { max(0, Date().timeIntervalSince1970 - $0) }
        await sendLog(CallLog(outcome: .completed, duration: duration, callId: held.callId),
                      held.chatId)
    }

    public func setMuted(_ muted: Bool) async {
        state.muted = muted
        await transport?.setMuted(muted)
        await room?.setMuted(muted)
    }

    /// Turns the local camera on or off. On a 1:1 call the first video track
    /// changes the SDP, so a renegotiation offer for the same call follows;
    /// the peer answers it on the live transport. In a room the SFU takes the
    /// new track on its own.
    public func setVideo(_ on: Bool) async {
        guard state.phase == .active || state.phase == .connecting, let callId = state.callId else { return }
        if let room {
            await room.setVideo(enabled: on)
            guard state.callId == callId else { return }
            state.localVideo = on
            return
        }
        guard let transport, let chatId = state.chatId else { return }
        await transport.setVideo(enabled: on)
        state.localVideo = on
        if let sdp = try? await transport.makeOffer(), state.callId == callId {
            await sendSignal(CallSignal(type: .offer, callId: callId, sdp: sdp, video: on), chatId)
        }
    }

    /// The transport a 1:1 call runs on, for the UI to reach media surfaces
    /// (video renderers) the core does not model.
    public func activeTransport() -> CallMediaTransport? { transport }

    /// The room a group call runs in, for the UI to reach its video tracks.
    public func activeRoom() -> CallRoomSession? { room }

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
        case .room:
            // the peer of the running 1:1 call moved it into a room
            if event.signal.callId == state.callId, !state.isRoom, transport != nil,
               event.fromUserId == state.peerUserId,
               state.phase == .active || state.phase == .connecting {
                await followIntoRoom(event)
                return
            }
            // a repeat of the invite into the room this device is in
            if event.signal.callId == state.callId { return }
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
            guard let candidates = event.signal.candidates, !candidates.isEmpty else { return }
            guard event.signal.callId == state.callId else {
                // ahead of its offer: keep it until the offer lands
                if earlyCandidates.count >= 2, earlyCandidates[event.signal.callId] == nil {
                    earlyCandidates = [:]
                }
                earlyCandidates[event.signal.callId, default: []].append(contentsOf: candidates)
                return
            }
            if event.fromUserId == state.peerUserId, let transport {
                await transport.add(candidates: candidates)
            } else if event.fromUserId == state.peerUserId {
                heldRemoteCandidates.append(contentsOf: candidates)
            }
        case .hold:
            // the peer of the live call, or of the parked one, went on hold
            // or came back; either way it is their silence, shown as such
            if event.signal.callId == state.callId, event.fromUserId == state.peerUserId {
                state.remoteHold = event.signal.held == true
            } else if var held = heldCall, event.signal.callId == held.callId,
                      event.fromUserId == held.peerUserId {
                held.remoteHold = event.signal.held == true
                heldCall = held
            }
        case .end:
            // the waiting caller gave up (cancel or timeout on their side)
            if let waiting = waitingOffer, event.signal.callId == waiting.signal.callId,
               event.fromUserId == waiting.fromUserId {
                waitingOffer = nil
                state.waitingCallerId = nil
                return
            }
            // the peer of the parked call hung up: the hold slot empties, the
            // live call stands
            if let held = heldCall, event.signal.callId == held.callId,
               event.fromUserId == held.peerUserId {
                await dropHeld(held)
                return
            }
            guard event.signal.callId == state.callId else { return }
            // in a room the roster is the SFU's word: a decline or a busy
            // from someone invited changes nothing here, and whoever leaves
            // is gone from the participants. Only the invite being cancelled
            // while this device rings still means something
            if state.isRoom, state.phase != .ringing { return }
            guard event.fromUserId == state.peerUserId else { return }
            await teardown(showing: .ended(event.signal.reason ?? .hangup))
        }
    }

    /// Whether the offer can wait behind the live call. Only a standing call
    /// takes a waiter, one at a time, and the privacy gate still applies —
    /// re-checked after its await in case the call moved meanwhile.
    private func holdAsWaiting(_ event: CallSignalEvent) async -> Bool {
        guard state.phase == .active, waitingOffer == nil,
              event.signal.sdp != nil || event.signal.key != nil,
              event.fromUserId != state.peerUserId,
              !state.participants.contains(where: { $0.userId == event.fromUserId }) else { return false }
        guard await mayCall(event.fromUserId) else { return false }
        guard state.phase == .active, waitingOffer == nil,
              event.signal.callId != state.callId else { return false }
        waitingOffer = event
        state.waitingCallerId = event.fromUserId
        return true
    }

    /// An offer or a room invite asking this device to ring.
    private func handleOffer(_ event: CallSignalEvent) async {
        // a fresh offer for the running call from its peer is the caller
        // restarting ICE or renegotiating video: answered in place
        if event.signal.type == .offer, event.signal.callId == state.callId,
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
            state.isRoom = event.signal.type == .room
            await accept()
            return
        }
        // one call at a time on the wire — but a second caller during a live
        // call waits on the screen for the user's word; anywhere earlier in
        // the call, and for anyone the privacy setting shuts out, busy
        guard case .idle = state.phase else {
            guard event.signal.callId != state.callId else { return }
            if await holdAsWaiting(event) { return }
            await sendSignal(CallSignal(type: .end, callId: event.signal.callId, reason: .busy),
                             event.chatId)
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
        state.isRoom = event.signal.type == .room
        // the ringing screen says what kind of call is asking
        state.remoteVideo = event.signal.video == true
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

    /// Closes the 1:1 transport and everything that served it, leaving the
    /// call itself standing: the step before the room takes the media over.
    private func closeTransport() async {
        transportTask?.cancel()
        transportTask = nil
        candidateFlushTask?.cancel()
        candidateFlushTask = nil
        iceRestartTask?.cancel()
        iceRestartTask = nil
        outgoingCandidates = []
        heldRemoteCandidates = []
        if let transport {
            self.transport = nil
            await transport.close()
        }
    }

    // MARK: - Room events

    private func consumeRoom(_ room: CallRoomSession) {
        let events = room.events()
        roomTask = Task { [weak self] in
            for await event in events {
                await self?.handleRoom(event)
            }
        }
    }

    private func handleRoom(_ event: CallRoomEvent) async {
        switch event {
        case .connected:
            state.reconnecting = false
        case .microphone(let available):
            // the control tells the truth: no microphone track means muted,
            // and the unmute tap is what asks the room to try the input again
            if !available { state.muted = true }
        case .reconnecting:
            state.reconnecting = true
        case .reconnected:
            state.reconnecting = false
        case .participants(let list):
            let sorted = list.sorted { $0.userId < $1.userId }
            let rosterChanged = sorted.map(\.userId) != state.participants.map(\.userId)
            state.participants = sorted
            // the opener waits as «calling» until the first person walks in
            if state.phase == .dialing, !sorted.isEmpty {
                dialTimeoutTask?.cancel()
                dialTimeoutTask = nil
                state.phase = .active
                state.connectedAt = Date().timeIntervalSince1970
            }
            if rosterChanged, state.phase == .active, isCardWriter {
                await refreshLiveCards()
            }
            // the joiner's first roster arrives while the join is still
            // completing, so connecting counts as in
            if sorted.isEmpty, state.phase == .active || state.phase == .connecting {
                armEmptyRoomTimeout()
            } else {
                emptyRoomTask?.cancel()
                emptyRoomTask = nil
            }
        case .disconnected(let failed):
            MsngrLog.call.error("room disconnected call=\(self.state.callId ?? "-", privacy: .public) failed=\(failed, privacy: .public)")
            await finish(reason: failed ? .failed : .hangup, notifyPeer: false)
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

    private func armEmptyRoomTimeout() {
        guard emptyRoomTask == nil else { return }
        let callId = state.callId
        let timeout = emptyRoomTimeout
        emptyRoomTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.emptyRoomTimedOut(callId: callId)
        }
    }

    private func emptyRoomTimedOut(callId: String?) async {
        emptyRoomTask = nil
        guard state.isRoom, state.phase == .active, state.callId == callId,
              state.participants.isEmpty else { return }
        await finish(reason: .hangup, notifyPeer: false)
    }

    private func finish(reason: CallSignal.EndReason, notifyPeer: Bool) async {
        if notifyPeer, let chatId = state.chatId, let callId = state.callId, !state.isRoom {
            await sendSignal(CallSignal(type: .end, callId: callId, reason: reason), chatId)
        }
        await teardown(showing: .ended(reason))
    }

    private func teardown(showing phase: CallPhase) async {
        if case .ended(let reason) = phase {
            MsngrLog.call.info("call ended call=\(self.state.callId ?? "-", privacy: .public) room=\(self.state.isRoom, privacy: .public) from=\(String(describing: self.state.phase), privacy: .public) reason=\(reason.rawValue, privacy: .public)")
            await publishLog(reason: reason)
            await closeCardsOnLeaving()
        }
        var next = state
        next.phase = phase
        next.muted = false
        next.localVideo = false
        next.remoteVideo = false
        next.participants = []
        next.reconnecting = false
        // claimed before teardown, which clears the early buffer whole
        let waitingEarly = waitingOffer.flatMap { earlyCandidates[$0.signal.callId] } ?? []
        await teardown(showing: next)
        // whoever was waiting behind the ended call rings in its place
        if case .ended = phase, let waiting = waitingOffer {
            waitingOffer = nil
            pendingOffer = waiting
            heldRemoteCandidates = waitingEarly
            isCaller = false
            state = CallState(phase: .ringing, chatId: waiting.chatId,
                              peerUserId: waiting.fromUserId, callId: waiting.signal.callId)
            state.isRoom = waiting.signal.type == .room
            state.remoteVideo = waiting.signal.video == true
            state.heldPeerId = heldCall?.peerUserId
            return
        }
        // no waiter: the parked call, if any, speaks again
        if case .ended = phase, let held = heldCall {
            heldCall = nil
            state = CallState(phase: .active, chatId: held.chatId,
                              peerUserId: held.peerUserId, callId: held.callId)
            await unpark(held)
        }
    }

    /// What this device's leaving does to the call's cards. A 1:1 call, or a
    /// room this device leaves empty, is over: the cards close everywhere,
    /// this device's copies included, whether or not anyone else's edit ever
    /// comes. A room with people still in it lives on: the card writer hands
    /// over the roster without itself, and nothing closes.
    private func closeCardsOnLeaving() async {
        guard let callId = state.callId else { return }
        let othersRemain = state.isRoom && !state.participants.isEmpty
        if othersRemain {
            if isCardWriter {
                await refreshLiveCards(members: state.participants.map(\.userId).sorted())
            }
            liveCardChats = []
            return
        }
        await refreshLiveCards(endedAt: Date().timeIntervalSince1970)
        if state.connectedAt != nil { await endLiveCards(callId) }
    }

    /// The caller alone writes a 1:1 call into the feed, once the outcome is
    /// known: how it ended, and for a completed call how long it ran. A room
    /// call leaves its card instead: nobody there is the caller.
    private func publishLog(reason: CallSignal.EndReason) async {
        guard isCaller, !state.isRoom, let chatId = state.chatId, let callId = state.callId else { return }
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
        roomTask?.cancel()
        roomTask = nil
        emptyRoomTask?.cancel()
        emptyRoomTask = nil
        outgoingCandidates = []
        heldRemoteCandidates = []
        earlyCandidates = [:]
        pendingOffer = nil
        roomKey = nil
        liveCardChats = []
        if let room {
            self.room = nil
            await room.leave()
        }
        if let transport {
            self.transport = nil
            await transport.close()
        }
        state = next
    }
}
