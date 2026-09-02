import AVFoundation
import Foundation
import LiveKit
import MsngrCore

/// A group call's room on the SFU, through the LiveKit SDK: this device's
/// microphone and camera go up, everyone else's tracks come down, and every
/// frame is encrypted under the call's shared key before it leaves the
/// device — the SFU forwards ciphertext. Driven by `CallManager` through the
/// `CallRoomSession` seam.
public final class LiveKitRoomSession: NSObject, CallRoomSession, @unchecked Sendable {
    public enum SessionError: Error {
        case notConnected
    }

    private let room = Room()
    private let eventStream: AsyncStream<CallRoomEvent>
    private let continuation: AsyncStream<CallRoomEvent>.Continuation
    private let lock = NSLock()
    private var leaving = false
    /// the simulator's camera stand-in: a buffer track fed by a timer
    private var syntheticTrack: LocalVideoTrack?
    private var syntheticTimer: DispatchSourceTimer?
    private let syntheticQueue = DispatchQueue(label: "msngr.room-synthetic-video")

    public override init() {
        var cont: AsyncStream<CallRoomEvent>.Continuation!
        eventStream = AsyncStream { cont = $0 }
        continuation = cont
        super.init()
        room.add(delegate: self)
    }

    public func events() -> AsyncStream<CallRoomEvent> { eventStream }

    public func join(url: String, token: String, key: String, video: Bool) async throws {
        // the permission question is asked before the room, so the connect
        // does not sit behind a dialog and a refusal joins the room muted
        // rather than failing the call
        let micAllowed = await Self.requestMicrophone()
        let options = RoomOptions(adaptiveStream: true, dynacast: true,
                                  encryptionOptions: .sharedKey(key))
        try await room.connect(url: url, token: token, roomOptions: options)
        var micUp = false
        if micAllowed {
            // the audio engine can refuse its input (on the simulator the
            // host's microphone is held by one simulator at a time); one more
            // try a moment later, and a second refusal joins muted rather
            // than failing
            for attempt in 0..<2 {
                if await publishMicrophone() { micUp = true; break }
                MsngrLog.call.error("room microphone publish failed attempt=\(attempt, privacy: .public)")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        if video { await setVideo(enabled: true) }
        continuation.yield(.microphone(available: micUp))
        continuation.yield(.connected)
        publishParticipants()
    }

    private func publishMicrophone() async -> Bool {
        do {
            try await room.localParticipant.setMicrophone(enabled: true)
            return true
        } catch {
            MsngrLog.call.error("room microphone publish error=\(String(describing: error), privacy: .public)")
            return false
        }
    }

    private static func requestMicrophone() async -> Bool {
        if #available(iOS 17, macOS 14, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return true
            case .denied: return false
            default: return await AVAudioApplication.requestRecordPermission()
            }
        }
        return true
    }

    public func setMuted(_ muted: Bool) async {
        guard let publication = room.localParticipant.firstAudioPublication as? LocalTrackPublication else {
            // no microphone track went up at the join: unmuting is the
            // moment to try the input again, and it stays muted if it fails
            if !muted, !(await publishMicrophone()) {
                continuation.yield(.microphone(available: false))
            }
            return
        }
        if muted {
            try? await publication.mute()
        } else {
            try? await publication.unmute()
        }
    }

    /// The device camera when there is one; the simulator has none, so the
    /// synthetic pattern goes up as the camera track and the whole pipeline
    /// — encryption, SFU, remote render — runs for real there too.
    public func setVideo(enabled: Bool) async {
        #if targetEnvironment(simulator)
        if enabled {
            guard syntheticTrack == nil else { return }
            let track = LocalVideoTrack.createBufferTrack(
                name: Track.cameraName, source: .camera,
                options: BufferCaptureOptions(dimensions: Dimensions(width: 640, height: 480)))
            syntheticTrack = track
            // frames first: the publish waits for the track's dimensions,
            // and a buffer track learns them from its first frame
            startSyntheticFrames(into: track)
            do {
                try await room.localParticipant.publish(videoTrack: track)
            } catch {
                MsngrLog.call.error("room camera publish failed error=\(String(describing: error), privacy: .public)")
                stopSyntheticFrames()
                syntheticTrack = nil
            }
        } else {
            stopSyntheticFrames()
            if let track = syntheticTrack {
                syntheticTrack = nil
                if let publication = room.localParticipant.trackPublications.values
                    .first(where: { $0.track === track }) as? LocalTrackPublication {
                    try? await room.localParticipant.unpublish(publication: publication)
                }
            }
        }
        #else
        try? await room.localParticipant.setCamera(enabled: enabled)
        #endif
    }

    /// Flips between the front and back camera on a device.
    public func switchCamera() {
        guard let capturer = (room.localParticipant.firstCameraPublication?.track as? LocalVideoTrack)?
            .capturer as? CameraCapturer else { return }
        Task { _ = try? await capturer.switchCameraPosition() }
    }

    public func leave() async {
        lock.lock(); leaving = true; lock.unlock()
        stopSyntheticFrames()
        await room.disconnect()
        continuation.finish()
    }

    // MARK: - Tracks for the screen

    /// The camera track of a participant, when their camera is on.
    public func videoTrack(for userId: String) -> VideoTrack? {
        room.remoteParticipants[Participant.Identity(from: userId)]?.firstCameraVideoTrack
    }

    /// This device's camera track, when the camera is on.
    public var localVideoTrack: VideoTrack? {
        room.localParticipant.firstCameraPublication?.track as? VideoTrack
    }

    // MARK: - Synthetic camera

    private func startSyntheticFrames(into track: LocalVideoTrack) {
        guard let capturer = track.capturer as? BufferCapturer else { return }
        let timer = DispatchSource.makeTimerSource(queue: syntheticQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(1000 / 15))
        timer.setEventHandler {
            guard let buffer = SyntheticFrames.make(width: 640, height: 480) else { return }
            capturer.capture(buffer)
        }
        timer.resume()
        syntheticTimer = timer
    }

    private func stopSyntheticFrames() {
        syntheticTimer?.cancel()
        syntheticTimer = nil
    }

    // MARK: - Roster

    private func publishParticipants() {
        let list = room.remoteParticipants.values.compactMap { p -> CallParticipant? in
            guard let identity = p.identity?.stringValue else { return nil }
            return CallParticipant(userId: identity,
                                   speaking: p.isSpeaking,
                                   muted: p.firstAudioPublication.map(\.isMuted) ?? true,
                                   video: p.firstCameraVideoTrack != nil)
        }
        continuation.yield(.participants(list))
    }
}

extension LiveKitRoomSession: RoomDelegate {
    public func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState,
                     from oldConnectionState: ConnectionState) {
        MsngrLog.call.info("room state \(String(describing: oldConnectionState), privacy: .public) -> \(String(describing: connectionState), privacy: .public)")
        switch connectionState {
        case .reconnecting:
            continuation.yield(.reconnecting)
        case .connected where oldConnectionState == .reconnecting:
            continuation.yield(.reconnected)
            publishParticipants()
        case .disconnected where oldConnectionState != .connecting:
            lock.lock(); let leaving = self.leaving; lock.unlock()
            guard !leaving else { return }
            continuation.yield(.disconnected(failed: oldConnectionState == .reconnecting))
        default:
            break
        }
    }

    public func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        publishParticipants()
    }

    public func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        publishParticipants()
    }

    public func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        publishParticipants()
    }

    public func room(_ room: Room, participant: Participant, trackPublication: TrackPublication,
                     didUpdateIsMuted isMuted: Bool) {
        publishParticipants()
    }

    public func room(_ room: Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) {
        publishParticipants()
    }

    public func room(_ room: Room, participant: RemoteParticipant, didUnpublishTrack publication: RemoteTrackPublication) {
        publishParticipants()
    }

    public func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        publishParticipants()
    }

    public func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        publishParticipants()
    }
}
