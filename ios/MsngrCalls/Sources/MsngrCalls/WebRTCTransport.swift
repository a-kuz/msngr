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

    /// Servers for NAT traversal. The default is plain STUN — address
    /// discovery only, no media through anyone. A relay for the paths STUN
    /// cannot open would be our own coturn, added here when it exists.
    public init(iceServers: [String] = ["stun:stun.l.google.com:19302"]) throws {
        let config = RTCConfiguration()
        config.iceServers = [RTCIceServer(urlStrings: iceServers)]
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

    public func close() async {
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
}
