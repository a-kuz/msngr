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
                candidates: [IceCandidate]? = nil, reason: EndReason? = nil) {
        self.type = type
        self.callId = callId
        self.sdp = sdp
        self.candidates = candidates
        self.reason = reason
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
