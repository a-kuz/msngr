import SwiftUI
import MsngrCalls
import WebRTC

/// The peer's video, rendered full-bleed behind the call controls.
struct RemoteVideoView: UIViewRepresentable {
    let transport: WebRTCTransport

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFill
        transport.attachRemote(view)
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {}
}

/// This side's camera, as the small self-view tile.
struct LocalVideoView: UIViewRepresentable {
    let transport: WebRTCTransport

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFill
        transport.attachLocal(view)
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {}
}
