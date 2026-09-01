import Foundation

/// One step of a call's signaling: the offer that starts it, the answer that
/// picks it up, trickled ICE candidates, and the end that closes it from
/// either side.
///
/// A signal travels as E2EE service content (kind `call`): it takes a seq and
/// reaches every device of both sides, raises no unread count, no push and no
/// feed row. Delivery to the running call machinery is in-memory only
/// (`SyncEngine.callSignalStream`); nothing is stored, and a signal replayed
/// from the journal after its moment has passed is dropped by freshness
/// (`isFresh`) and by the call state it no longer matches.
public struct CallSignal: Codable, Equatable, Sendable {
    public enum SignalType: String, Codable, Sendable {
        /// starts the call: carries the caller's SDP offer
        case offer
        /// accepts it: carries the callee's SDP answer
        case answer
        /// trickled ICE candidates, any number of frames per call
        case ice
        /// closes the call from either side, `reason` says how
        case end
    }

    /// Why a call ended. `hangup` after it was up, `cancel` by the caller
    /// still ringing, `decline` and `busy` by the callee, `timeout` by the
    /// caller nobody answered, `failed` when the transport gave up.
    public enum EndReason: String, Codable, Sendable {
        case hangup, cancel, decline, busy, timeout, failed
    }

    public var type: SignalType
    /// One call, one id: every signal of the call carries it, and glare (both
    /// sides dialing at once) is settled by comparing the two ids.
    public var callId: String
    /// offer / answer: the SDP
    public var sdp: String?
    /// ice: candidates as (sdpMid, sdpMLineIndex, candidate) triples
    public var candidates: [IceCandidate]?
    public var reason: EndReason?
    /// offer: whether the sender's camera is on — carried on renegotiation
    /// so the peer learns the camera went off (the track alone only freezes)
    public var video: Bool?
    /// offer into a conference: everyone already in the call, so the invited
    /// side knows whom else to link up with. Knowing the callId is the ticket:
    /// only a participant has it, so a same-callId offer joins without ringing.
    public var members: [String]?

    public struct IceCandidate: Codable, Equatable, Sendable {
        public var sdpMid: String?
        public var sdpMLineIndex: Int32
        public var candidate: String

        public init(sdpMid: String?, sdpMLineIndex: Int32, candidate: String) {
            self.sdpMid = sdpMid
            self.sdpMLineIndex = sdpMLineIndex
            self.candidate = candidate
        }
    }

    public init(type: SignalType, callId: String, sdp: String? = nil,
                candidates: [IceCandidate]? = nil, reason: EndReason? = nil,
                video: Bool? = nil, members: [String]? = nil) {
        self.type = type
        self.callId = callId
        self.sdp = sdp
        self.candidates = candidates
        self.reason = reason
        self.video = video
        self.members = members
    }

    /// The `ContentPayload` kind a call signal travels under.
    public static let kind = "call"

    /// An offer older than this can no longer be answered: whoever sent it has
    /// given up ringing, so a copy replayed from the journal must not ring here.
    public static let offerLifetime: TimeInterval = 60

    /// Whether a signal sent at `sentAt` is still worth delivering `now`.
    /// Only an offer rings, so only an offer has a freshness bar; the other
    /// types are cheap to deliver and are judged against the call's state.
    public func isFresh(sentAt: Double, now: Double = Date().timeIntervalSince1970) -> Bool {
        guard type == .offer else { return true }
        return now - sentAt < Self.offerLifetime
    }

    /// The form the envelope carries, in `ContentPayload.text`.
    public var encoded: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(_ text: String?) -> CallSignal? {
        guard let text else { return nil }
        return try? JSONDecoder().decode(CallSignal.self, from: Data(text.utf8))
    }
}

/// The record a finished call leaves in the feed: who called whom and how it
/// ended. The caller sends it once the call is over, service-flagged like a
/// group event — a seq and a feed row on both sides, no unread count and no
/// push. The callee's side derives direction from the row's sender.
public struct CallLog: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// media flowed; `duration` says for how long
        case completed
        /// nobody picked up: the caller gave up or ran out of ring time
        case missed
        case declined
        case busy
        case failed
    }

    public var outcome: Outcome
    /// completed only: seconds of talk
    public var duration: Double?
    public var callId: String

    public init(outcome: Outcome, duration: Double? = nil, callId: String) {
        self.outcome = outcome
        self.duration = duration
        self.callId = callId
    }

    /// The `ContentPayload` kind a call log travels under.
    public static let kind = "callLog"
    /// Marks the text of a `.call` feed row as a call log.
    public static let prefix = "call:"

    /// The form the message row and the envelope carry.
    public var encoded: String {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else { return Self.prefix }
        return Self.prefix + json
    }

    public static func decode(_ text: String?) -> CallLog? {
        guard let text, text.hasPrefix(prefix) else { return nil }
        return try? JSONDecoder().decode(CallLog.self, from: Data(text.dropFirst(prefix.count).utf8))
    }
}

extension Message {
    /// The call log of a `.call` row, decoded from its text.
    public var callLog: CallLog? { CallLog.decode(text) }
}

/// A call signal as it reaches the running call machinery.
public struct CallSignalEvent: Sendable {
    public let chatId: String
    public let fromUserId: String
    /// which of the sender's devices speaks; the answering device wins the
    /// call, the others stop ringing on its answer echo
    public let fromDeviceId: String
    public let sentAt: Double
    public let signal: CallSignal
}
