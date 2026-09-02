import SwiftUI
import GRDB
import MsngrCore
import MsngrCalls

/// The call, full screen over everything but the passcode: who, what phase,
/// and the few controls a call has. Shown while `AppState.callState` is not
/// idle; an ended call shows its outcome briefly and dismisses itself.
struct CallScreenView: View {
    @EnvironmentObject private var app: AppState
    @State private var peer: User?
    @State private var extraNames: [String] = []
    @State private var waitingName: String?
    @State private var heldName: String?
    @State private var transport: WebRTCTransport?
    @State private var invitePickerShown = false

    private var state: CallState { app.callState }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(.systemIndigo).opacity(0.6), Color(.systemBackground)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            // while ringing, remoteVideo only says what kind of call is
            // asking; the stream itself starts with the media
            if remoteVideoShown, let transport {
                RemoteVideoView(transport: transport)
                    .ignoresSafeArea()
            }
            VStack(spacing: 0) {
                Spacer()
                if !remoteVideoShown {
                    AvatarView(name: peer?.displayName ?? "", avatarId: peer?.avatarId)
                        .frame(width: 104, height: 104)
                    Text(names)
                        .textRole(Theme.Text.callName)
                        .multilineTextAlignment(.center)
                        .padding(.top, 20)
                        .padding(.horizontal, 24)
                    statusLine
                        .padding(.top, 6)
                }
                Spacer()
                controls
                    .padding(.bottom, 56)
            }
            if state.localVideo, let transport {
                FloatingTile(margin: 14) {
                    LocalVideoView(transport: transport)
                        .frame(width: 108, height: 144)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(alignment: .bottomTrailing) {
                            Button {
                                transport.switchCamera()
                            } label: {
                                Image(systemName: "arrow.triangle.2.circlepath.camera")
                                    .font(Theme.glyph(13, max: 17))
                                    .foregroundStyle(.white)
                                    .padding(6)
                                    .background(Circle().fill(.black.opacity(0.35)))
                            }
                            .padding(4)
                            .accessibilityIdentifier("call.flipCamera")
                        }
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                }
                .padding(.top, 52)
            }
        }
        // re-read on every state change: the screen appears the instant the
        // phase leaves idle, which is before startCall has built the transport
        .task(id: state) {
            transport = await app.callManager?.activeTransport() as? WebRTCTransport
        }
        .overlay(alignment: .topLeading) {
            if minimizable {
                Button {
                    app.callMinimized = true
                } label: {
                    topGlyph("chevron.down")
                }
                .padding(.leading, 8)
                .accessibilityIdentifier("call.minimize")
            }
        }
        .overlay(alignment: .topTrailing) {
            // pulling a third person in: only on a standing call, and the
            // mesh carries three at most
            if state.phase == .active, state.extraPeers.count < 2, !state.localVideo {
                Button {
                    invitePickerShown = true
                } label: {
                    topGlyph("person.badge.plus")
                }
                .padding(.trailing, 8)
                .accessibilityIdentifier("call.invite")
            }
        }
        .sheet(isPresented: $invitePickerShown) {
            CallInvitePicker(exclude: Set([app.session?.userId, state.peerUserId]
                                              .compactMap { $0 } + state.extraPeers)) { userId in
                Task { await app.callManager?.invite(userId: userId) }
            }
            .environmentObject(app)
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if state.waitingCallerId != nil {
                    waitingBanner
                }
                if state.heldPeerId != nil {
                    heldBanner
                }
            }
            .padding(.top, 52)
            .padding(.horizontal, 16)
        }
        // the screen owns the display whole: a keyboard left up by the chat
        // underneath must not squeeze the controls upward — nor stay on top
        // of them, so whatever holds focus lets it go
        .ignoresSafeArea(.keyboard)
        .onAppear {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                            to: nil, from: nil, for: nil)
        }
        .task(id: "\(state.peerUserId ?? "")|\(state.extraPeers.joined(separator: ","))|\(state.waitingCallerId ?? "")|\(state.heldPeerId ?? "")") {
            await loadPeer()
        }
        .accessibilityIdentifier("call.screen")
    }

    /// Someone else is calling behind the live call: refuse them, or end
    /// this call and take theirs.
    private var waitingBanner: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(waitingName ?? "…")
                    .textRole(Theme.Text.callControlLabel)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text("Incoming call")
                    .textRole(Theme.Text.callControlLabel)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button {
                Task { await app.callManager?.declineWaiting() }
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(Theme.glyph(15, max: 19))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.red))
            }
            .accessibilityIdentifier("call.waiting.decline")
            Button {
                Task { await app.callManager?.acceptWaiting() }
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(Theme.glyph(15, max: 19))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.orange))
            }
            .accessibilityIdentifier("call.waiting.endAccept")
            Button {
                Task { await app.callManager?.holdAndAcceptWaiting() }
            } label: {
                Image(systemName: "phone.fill")
                    .font(Theme.glyph(15, max: 19))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.green))
            }
            .accessibilityIdentifier("call.waiting.accept")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 16).fill(.thinMaterial))
        .accessibilityIdentifier("call.waiting")
    }

    /// The call parked behind this one: who waits there, and the switch back.
    private var heldBanner: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(heldName ?? "…")
                    .textRole(Theme.Text.callControlLabel)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text("On hold")
                    .textRole(Theme.Text.callControlLabel)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button {
                Task { await app.callManager?.switchToHeld() }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(Theme.glyph(15, max: 19))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color(.systemGray)))
            }
            .accessibilityIdentifier("call.held.switch")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 16).fill(.thinMaterial))
        .accessibilityIdentifier("call.held")
    }

    /// While ringing, `remoteVideo` only says what kind of call is asking;
    /// the stream itself starts with the media.
    private var remoteVideoShown: Bool {
        state.remoteVideo && (state.phase == .active || state.phase == .connecting)
    }

    /// An ended call is about to dismiss itself; folding it away would only
    /// strand the outcome in the tile.
    private var minimizable: Bool {
        switch state.phase {
        case .dialing, .ringing, .connecting, .active: return true
        case .idle, .ended: return false
        }
    }

    private var statusLine: some View {
        Group {
            switch state.phase {
            case .idle:
                Text(verbatim: "")
            case .dialing:
                Text("Calling…")
            case .ringing:
                Text(state.remoteVideo ? "Incoming video call" : "Incoming call")
            case .connecting:
                Text("Connecting…")
            case .active:
                if state.remoteHold {
                    Text("On hold")
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(Self.duration(since: state.connectedAt))
                            .monospacedDigit()
                    }
                }
            case .ended(let reason):
                Text(Self.outcome(reason))
            }
        }
        .textRole(Theme.Text.callStatus)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("call.status")
    }

    private var controls: some View {
        HStack(spacing: 64) {
            switch state.phase {
            case .ringing:
                control(glyph: "phone.down.fill", color: .red, label: String(localized: "Decline"),
                        id: "call.decline") {
                    Task { await app.callManager?.decline() }
                }
                control(glyph: "phone.fill", color: .green, label: String(localized: "Accept"),
                        id: "call.accept") {
                    Task { await app.callManager?.accept() }
                }
            case .dialing, .connecting, .active:
                control(glyph: state.muted ? "mic.slash.fill" : "mic.fill",
                        color: state.muted ? .white : Color(.systemGray2),
                        label: String(localized: "Mute"), id: "call.mute") {
                    Task { await app.callManager?.setMuted(!state.muted) }
                }
                if state.phase == .active {
                    control(glyph: state.localVideo ? "video.fill" : "video.slash.fill",
                            color: state.localVideo ? .white : Color(.systemGray2),
                            label: String(localized: "Camera"), id: "call.video") {
                        Task { await app.callManager?.setVideo(!state.localVideo) }
                    }
                }
                control(glyph: "phone.down.fill", color: .red, label: String(localized: "End call"),
                        id: "call.hangup") {
                    Task { await app.callManager?.hangUp() }
                }
            case .idle, .ended:
                EmptyView()
            }
        }
        .animation(nil, value: state.phase)
    }

    /// A corner button of the call screen: a white glyph on a dark disc, so it
    /// stands on the gradient and on a video frame alike.
    private func topGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(Theme.glyph(17, max: 22))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(Circle().fill(.black.opacity(0.35)))
            .padding(3)
            .contentShape(Rectangle())
    }

    private func control(glyph: String, color: Color, label: String, id: String,
                         action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: glyph)
                    .font(Theme.glyph(26, max: 34))
                    .foregroundStyle(.white)
                    .frame(width: 68, height: 68)
                    .background(Circle().fill(color == .white ? Color(.systemGray) : color))
            }
            .accessibilityIdentifier(id)
            Text(label)
                .textRole(Theme.Text.callControlLabel)
                .foregroundStyle(.secondary)
        }
    }

    /// Everyone on the call, the primary peer first.
    private var names: String {
        ([peer?.displayName ?? "…"] + extraNames).joined(separator: ", ")
    }

    private func loadPeer() async {
        guard let id = state.peerUserId, let db = app.db else {
            peer = nil
            extraNames = []
            waitingName = nil
            heldName = nil
            return
        }
        let extras = state.extraPeers
        let waitingId = state.waitingCallerId
        let heldId = state.heldPeerId
        let loaded = try? await db.read { dbc -> (User?, [String], String?, String?) in
            func name(_ userId: String) throws -> String? {
                try User.fetchOne(dbc, key: userId)
                    .map { try ContactBookName.applied(dbc, to: $0).displayName }
            }
            let peer = try User.fetchOne(dbc, key: id)
                .map { try ContactBookName.applied(dbc, to: $0) }
            let names = try extras.compactMap { try name($0) }
            return (peer, names, try waitingId.flatMap { try name($0) },
                    try heldId.flatMap { try name($0) })
        }
        peer = loaded?.0
        extraNames = loaded?.1 ?? []
        waitingName = loaded?.2
        heldName = loaded?.3
    }

    private static func duration(since start: Double?) -> String {
        guard let start else { return "0:00" }
        let seconds = max(0, Int(Date().timeIntervalSince1970 - start))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static func outcome(_ reason: CallSignal.EndReason) -> String {
        switch reason {
        case .hangup, .cancel: return String(localized: "Call ended")
        case .decline: return String(localized: "Call declined")
        case .busy: return String(localized: "Busy")
        case .timeout: return String(localized: "No answer")
        case .failed: return String(localized: "Call failed")
        }
    }
}
