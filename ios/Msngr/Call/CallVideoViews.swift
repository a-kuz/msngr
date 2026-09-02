import SwiftUI
import MsngrCalls
import LiveKitWebRTC

/// The peer's video, rendered full-bleed behind the call controls.
struct RemoteVideoView: UIViewRepresentable {
    let transport: WebRTCTransport

    func makeUIView(context: Context) -> LKRTCMTLVideoView {
        let view = LKRTCMTLVideoView()
        view.videoContentMode = .scaleAspectFill
        transport.attachRemote(view)
        return view
    }

    func updateUIView(_ uiView: LKRTCMTLVideoView, context: Context) {}
}

/// This side's camera, as the small self-view tile.
struct LocalVideoView: UIViewRepresentable {
    let transport: WebRTCTransport

    func makeUIView(context: Context) -> LKRTCMTLVideoView {
        let view = LKRTCMTLVideoView()
        view.videoContentMode = .scaleAspectFill
        transport.attachLocal(view)
        return view
    }

    func updateUIView(_ uiView: LKRTCMTLVideoView, context: Context) {}
}
