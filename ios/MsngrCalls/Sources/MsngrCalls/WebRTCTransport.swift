import AVFoundation
import Foundation
import MsngrCore
import LiveKitWebRTC

/// The WebRTC half of a 1:1 call: one peer connection with one audio track,
/// driven by `CallManager` through the `CallMediaTransport` seam.
///
/// Media is end-to-end encrypted by DTLS-SRTP on the connection itself; the
/// SDP and candidates travel inside the messenger's own E2EE envelopes, so
/// the signaling path cannot be used to slip a different endpoint in.
public final class WebRTCTransport: NSObject, CallMediaTransport, @unchecked Sendable {
    public enum TransportError: Error {
        case peerConnectionFailed
        case sdpMissing
    }

    private static let factory: LKRTCPeerConnectionFactory = {
        LKRTCInitializeSSL()
        return LKRTCPeerConnectionFactory(
            encoderFactory: LKRTCDefaultVideoEncoderFactory(),
            decoderFactory: LKRTCDefaultVideoDecoderFactory())
    }()

    private let pc: LKRTCPeerConnection
    private let audioTrack: LKRTCAudioTrack
    private let eventStream: AsyncStream<CallTransportEvent>
    private let continuation: AsyncStream<CallTransportEvent>.Continuation

    // Video is created lazily: an audio call never touches the camera.
    private var videoSource: LKRTCVideoSource?
    private var videoTrack: LKRTCVideoTrack?
    private var capturer: LKRTCVideoCapturer?
    private var remoteVideoTrack: LKRTCVideoTrack?
    private var localRenderer: LKRTCVideoRenderer?
    private var remoteRenderer: LKRTCVideoRenderer?
    private var cameraPosition: AVCaptureDevice.Position = .front

    /// Servers for NAT traversal: plain STUN for address discovery, and our
    /// own coturn on the stand's server relaying the paths STUN cannot open
    /// (both ends behind symmetric NAT). Media through the relay is still
    /// DTLS-SRTP: the relay forwards ciphertext it cannot read.
    public struct IceServer {
        public var urls: [String]
        public var username: String?
        public var credential: String?
        public init(urls: [String], username: String? = nil, credential: String? = nil) {
            self.urls = urls
            self.username = username
            self.credential = credential
        }
    }

    public static let defaultIceServers = [
        IceServer(urls: ["stun:stun.l.google.com:19302"]),
        IceServer(urls: ["turn:167.235.200.232:3478?transport=udp",
                         "turn:167.235.200.232:3478?transport=tcp"],
                  username: "msngr", credential: "2SPcjPIWJVo-y8IYZLYTE9CJ"),
    ]

    public init(iceServers: [IceServer] = WebRTCTransport.defaultIceServers) throws {
        let config = LKRTCConfiguration()
        config.iceServers = iceServers.map { server in
            if let user = server.username, let pass = server.credential {
                return LKRTCIceServer(urlStrings: server.urls, username: user, credential: pass)
            }
            return LKRTCIceServer(urlStrings: server.urls)
        }
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = Self.factory.peerConnection(with: config, constraints: constraints,
                                                   delegate: nil) else {
            throw TransportError.peerConnectionFailed
        }
        self.pc = pc
        let source = Self.factory.audioSource(
            with: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        audioTrack = Self.factory.audioTrack(with: source, trackId: "audio0")
        var cont: AsyncStream<CallTransportEvent>.Continuation!
        eventStream = AsyncStream { cont = $0 }
        continuation = cont
        super.init()
        pc.add(audioTrack, streamIds: ["stream0"])
        pc.delegate = self
    }

    public func events() -> AsyncStream<CallTransportEvent> { eventStream }

    public func makeOffer() async throws -> String {
        let constraints = LKRTCMediaConstraints(
            mandatoryConstraints: [kLKRTCMediaConstraintsOfferToReceiveAudio: kLKRTCMediaConstraintsValueTrue],
            optionalConstraints: nil)
        let offer = try await pc.offer(for: constraints)
        try await pc.setLocalDescription(offer)
        return offer.sdp
    }

    public func restartOffer() async throws -> String {
        let constraints = LKRTCMediaConstraints(
            mandatoryConstraints: [kLKRTCMediaConstraintsOfferToReceiveAudio: kLKRTCMediaConstraintsValueTrue,
                                   kLKRTCMediaConstraintsIceRestart: kLKRTCMediaConstraintsValueTrue],
            optionalConstraints: nil)
        let offer = try await pc.offer(for: constraints)
        try await pc.setLocalDescription(offer)
        return offer.sdp
    }

    public func answerOffer(_ sdp: String) async throws -> String {
        try await pc.setRemoteDescription(LKRTCSessionDescription(type: .offer, sdp: sdp))
        let constraints = LKRTCMediaConstraints(
            mandatoryConstraints: [kLKRTCMediaConstraintsOfferToReceiveAudio: kLKRTCMediaConstraintsValueTrue],
            optionalConstraints: nil)
        let answer = try await pc.answer(for: constraints)
        try await pc.setLocalDescription(answer)
        return answer.sdp
    }

    public func acceptAnswer(_ sdp: String) async throws {
        try await pc.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: sdp))
    }

    public func add(candidates: [CallSignal.IceCandidate]) async {
        for c in candidates {
            let candidate = LKRTCIceCandidate(sdp: c.candidate,
                                              sdpMLineIndex: c.sdpMLineIndex,
                                              sdpMid: c.sdpMid)
            try? await pc.add(candidate)
        }
    }

    public func setMuted(_ muted: Bool) async {
        audioTrack.isEnabled = !muted
    }

    /// Holding silences the call both ways without closing it: nothing is
    /// sent and nothing is played, and the connection keeps standing. The
    /// camera is setVideo's business and is left alone.
    public func setHeld(_ held: Bool) async {
        audioTrack.isEnabled = !held
        for receiver in pc.receivers {
            (receiver.track as? LKRTCAudioTrack)?.isEnabled = !held
        }
    }

    public func setVideo(enabled: Bool) async {
        if enabled {
            if videoTrack == nil {
                let source = Self.factory.videoSource()
                let track = Self.factory.videoTrack(with: source, trackId: "video0")
                videoSource = source
                videoTrack = track
                pc.add(track, streamIds: ["stream0"])
                if let renderer = localRenderer { track.add(renderer) }
            }
            videoTrack?.isEnabled = true
            startCapture()
        } else {
            videoTrack?.isEnabled = false
            stopCapture()
        }
    }

    /// Flips between the front and back camera; a running capture restarts
    /// on the other one. The synthetic stand-in has nothing to flip.
    public func switchCamera() {
        cameraPosition = cameraPosition == .front ? .back : .front
        guard capturer is LKRTCCameraVideoCapturer else { return }
        stopCapture()
        startCapture()
    }

    /// The device camera when there is one; the simulator has none, so a
    /// synthetic pattern stands in and the pipeline stays exercisable there.
    private func startCapture() {
        guard let videoSource else { return }
        #if targetEnvironment(simulator)
        // the simulator lists a capture device but it never delivers a frame
        let device: AVCaptureDevice? = nil
        #else
        let device = LKRTCCameraVideoCapturer.captureDevices().first(where: { $0.position == cameraPosition })
            ?? LKRTCCameraVideoCapturer.captureDevices().first
        #endif
        if let device {
            let camera = LKRTCCameraVideoCapturer(delegate: videoSource)
            capturer = camera
            let formats = LKRTCCameraVideoCapturer.supportedFormats(for: device)
            // the smallest format at or above 480p keeps the encoder cheap
            let format = formats.min(by: {
                abs(CMVideoFormatDescriptionGetDimensions($0.formatDescription).height - 640)
                    < abs(CMVideoFormatDescriptionGetDimensions($1.formatDescription).height - 640)
            }) ?? formats[0]
            let fps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).min() ?? 24
            camera.startCapture(with: device, format: format, fps: Int(min(fps, 24)))
        } else {
            let synthetic = SyntheticVideoCapturer(delegate: videoSource)
            capturer = synthetic
            synthetic.start()
        }
    }

    private func stopCapture() {
        (capturer as? LKRTCCameraVideoCapturer)?.stopCapture()
        (capturer as? SyntheticVideoCapturer)?.stop()
        capturer = nil
    }

    // MARK: - Renderers (the UI's view onto the tracks)

    public func attachLocal(_ renderer: LKRTCVideoRenderer) {
        localRenderer = renderer
        videoTrack?.add(renderer)
    }

    public func attachRemote(_ renderer: LKRTCVideoRenderer) {
        remoteRenderer = renderer
        remoteVideoTrack?.add(renderer)
    }

    public func close() async {
        stopCapture()
        pc.close()
        continuation.finish()
    }
}

extension WebRTCTransport: LKRTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: LKRTCPeerConnection,
                               didGenerate candidate: LKRTCIceCandidate) {
        continuation.yield(.candidates([CallSignal.IceCandidate(
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: candidate.sdpMLineIndex,
            candidate: candidate.sdp)]))
    }

    public func peerConnection(_ peerConnection: LKRTCPeerConnection,
                               didChange newState: LKRTCIceConnectionState) {
        switch newState {
        case .connected, .completed:
            continuation.yield(.connected)
        case .disconnected:
            continuation.yield(.disconnected)
        case .failed:
            continuation.yield(.failed)
        default:
            break
        }
    }

    public func peerConnection(_ peerConnection: LKRTCPeerConnection,
                               didChange stateChanged: LKRTCSignalingState) {}
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    public func peerConnection(_ peerConnection: LKRTCPeerConnection,
                               didChange newState: LKRTCIceGatheringState) {}
    public func peerConnection(_ peerConnection: LKRTCPeerConnection,
                               didRemove candidates: [LKRTCIceCandidate]) {}
    public func peerConnection(_ peerConnection: LKRTCPeerConnection,
                               didOpen dataChannel: LKRTCDataChannel) {}

    public func peerConnection(_ peerConnection: LKRTCPeerConnection,
                               didAdd rtpReceiver: LKRTCRtpReceiver,
                               streams mediaStreams: [LKRTCMediaStream]) {
        guard let track = rtpReceiver.track as? LKRTCVideoTrack else { return }
        remoteVideoTrack = track
        if let renderer = remoteRenderer { track.add(renderer) }
        continuation.yield(.remoteVideo(true))
    }
}
