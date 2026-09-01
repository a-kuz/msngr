import AVFoundation
import Foundation
import MsngrCore
import WebRTC

/// The WebRTC half of a call: one peer connection with one audio track,
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

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    private let pc: RTCPeerConnection
    private let audioTrack: RTCAudioTrack
    private let eventStream: AsyncStream<CallTransportEvent>
    private let continuation: AsyncStream<CallTransportEvent>.Continuation

    // Video is created lazily: an audio call never touches the camera.
    private var videoSource: RTCVideoSource?
    private var videoTrack: RTCVideoTrack?
    private var capturer: RTCVideoCapturer?
    private var remoteVideoTrack: RTCVideoTrack?
    private var localRenderer: RTCVideoRenderer?
    private var remoteRenderer: RTCVideoRenderer?
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
        let config = RTCConfiguration()
        config.iceServers = iceServers.map { server in
            if let user = server.username, let pass = server.credential {
                return RTCIceServer(urlStrings: server.urls, username: user, credential: pass)
            }
            return RTCIceServer(urlStrings: server.urls)
        }
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = Self.factory.peerConnection(with: config, constraints: constraints,
                                                   delegate: nil) else {
            throw TransportError.peerConnectionFailed
        }
        self.pc = pc
        let source = Self.factory.audioSource(
            with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
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
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue],
            optionalConstraints: nil)
        let offer = try await pc.offer(for: constraints)
        try await pc.setLocalDescription(offer)
        return offer.sdp
    }

    public func restartOffer() async throws -> String {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                                   kRTCMediaConstraintsIceRestart: kRTCMediaConstraintsValueTrue],
            optionalConstraints: nil)
        let offer = try await pc.offer(for: constraints)
        try await pc.setLocalDescription(offer)
        return offer.sdp
    }

    public func answerOffer(_ sdp: String) async throws -> String {
        try await pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp))
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue],
            optionalConstraints: nil)
        let answer = try await pc.answer(for: constraints)
        try await pc.setLocalDescription(answer)
        return answer.sdp
    }

    public func acceptAnswer(_ sdp: String) async throws {
        try await pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp))
    }

    public func add(candidates: [CallSignal.IceCandidate]) async {
        for c in candidates {
            let candidate = RTCIceCandidate(sdp: c.candidate,
                                            sdpMLineIndex: c.sdpMLineIndex,
                                            sdpMid: c.sdpMid)
            try? await pc.add(candidate)
        }
    }

    public func setMuted(_ muted: Bool) async {
        audioTrack.isEnabled = !muted
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
        guard capturer is RTCCameraVideoCapturer else { return }
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
        let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == cameraPosition })
            ?? RTCCameraVideoCapturer.captureDevices().first
        #endif
        if let device {
            let camera = RTCCameraVideoCapturer(delegate: videoSource)
            capturer = camera
            let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
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
        (capturer as? RTCCameraVideoCapturer)?.stopCapture()
        (capturer as? SyntheticVideoCapturer)?.stop()
        capturer = nil
    }

    // MARK: - Renderers (the UI's view onto the tracks)

    public func attachLocal(_ renderer: RTCVideoRenderer) {
        localRenderer = renderer
        videoTrack?.add(renderer)
    }

    public func attachRemote(_ renderer: RTCVideoRenderer) {
        remoteRenderer = renderer
        remoteVideoTrack?.add(renderer)
    }

    public func close() async {
        stopCapture()
        pc.close()
        continuation.finish()
    }
}

extension WebRTCTransport: RTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: RTCPeerConnection,
                               didGenerate candidate: RTCIceCandidate) {
        continuation.yield(.candidates([CallSignal.IceCandidate(
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: candidate.sdpMLineIndex,
            candidate: candidate.sdp)]))
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection,
                               didChange newState: RTCIceConnectionState) {
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

    public func peerConnection(_ peerConnection: RTCPeerConnection,
                               didChange stateChanged: RTCSignalingState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection,
                               didChange newState: RTCIceGatheringState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection,
                               didRemove candidates: [RTCIceCandidate]) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection,
                               didOpen dataChannel: RTCDataChannel) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection,
                               didAdd rtpReceiver: RTCRtpReceiver,
                               streams mediaStreams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        remoteVideoTrack = track
        if let renderer = remoteRenderer { track.add(renderer) }
        continuation.yield(.remoteVideo(true))
    }
}
