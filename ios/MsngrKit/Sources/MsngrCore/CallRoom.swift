import Foundation

/// The ticket the server hands out for a group call's room on the SFU: where
/// to connect and the token that admits this user to the one room named by
/// the call. The frame key is not part of it — that travels inside the E2EE
/// `room` invite and the live card, and the server never holds it.
public struct CallRoomTicket: Decodable, Equatable, Sendable {
    public var url: String
    public var token: String

    public init(url: String, token: String) {
        self.url = url
        self.token = token
    }
}

/// One other person in the room, as the SFU reports them.
public struct CallParticipant: Equatable, Sendable, Identifiable {
    public var userId: String
    public var speaking = false
    /// their microphone is off
    public var muted = false
    /// their camera is sending
    public var video = false

    public var id: String { userId }

    public init(userId: String, speaking: Bool = false, muted: Bool = false, video: Bool = false) {
        self.userId = userId
        self.speaking = speaking
        self.muted = muted
        self.video = video
    }
}

/// What the room reports back to the call machinery.
public enum CallRoomEvent: Sendable {
    /// this device is in the room; media flows as soon as someone else is
    case connected
    /// whether this device's microphone went up: when it did not, the call
    /// runs muted and the mute control shows it, and unmuting tries again
    case microphone(available: Bool)
    /// the path to the SFU dropped; the session is trying to get it back
    case reconnecting
    case reconnected
    /// everyone else in the room right now, with their live state
    case participants([CallParticipant])
    /// the session is over: the SFU closed it, or the reconnect gave up
    case disconnected(failed: Bool)
}

/// The media half of a group call: a room on the SFU with every participant's
/// audio and video in it, frame-encrypted with a key the SFU never holds. The
/// production implementation wraps a LiveKit room; tests use a fake. One
/// session serves one call and is left with it.
public protocol CallRoomSession: AnyObject, Sendable {
    /// Connects and publishes the microphone (and the camera when `video`);
    /// returns once this device is in the room, throws when it cannot get in.
    func join(url: String, token: String, key: String, video: Bool) async throws
    func setMuted(_ muted: Bool) async
    func setVideo(enabled: Bool) async
    func leave() async
    func events() -> AsyncStream<CallRoomEvent>
}

/// The frame key of a room: 32 random bytes, base64, made by whoever opens
/// the room and handed to every participant inside the E2EE signaling.
public enum CallRoomKey {
    public static func make() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
    }
}
