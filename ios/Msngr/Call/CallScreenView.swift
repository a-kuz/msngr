import SwiftUI
import GRDB
import MsngrCore

/// The call, full screen over everything but the passcode: who, what phase,
/// and the few controls a call has. Shown while `AppState.callState` is not
/// idle; an ended call shows its outcome briefly and dismisses itself.
struct CallScreenView: View {
    @EnvironmentObject private var app: AppState
    @State private var peer: User?

    private var state: CallState { app.callState }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(.systemIndigo).opacity(0.6), Color(.systemBackground)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                AvatarView(name: peer?.displayName ?? "", avatarId: peer?.avatarId)
                    .frame(width: 104, height: 104)
                Text(peer?.displayName ?? "…")
                    .textRole(Theme.Text.callName)
                    .padding(.top, 20)
                statusLine
                    .padding(.top, 6)
                Spacer()
                controls
                    .padding(.bottom, 56)
            }
        }
        .overlay(alignment: .topLeading) {
            if minimizable {
                Button {
                    app.callMinimized = true
                } label: {
                    Image(systemName: "chevron.down")
                        .font(Theme.glyph(17, max: 22))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .padding(.leading, 8)
                .accessibilityIdentifier("call.minimize")
            }
        }
        // the screen owns the display whole: a keyboard left up by the chat
        // underneath must not squeeze the controls upward
        .ignoresSafeArea(.keyboard)
        .task(id: state.peerUserId) { await loadPeer() }
        .accessibilityIdentifier("call.screen")
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
                Text("Incoming call")
            case .connecting:
                Text("Connecting…")
            case .active:
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(Self.duration(since: state.connectedAt))
                        .monospacedDigit()
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

    private func loadPeer() async {
        guard let id = state.peerUserId, let db = app.db else {
            peer = nil
            return
        }
        peer = try? await db.read { dbc in
            try User.fetchOne(dbc, key: id).map { try ContactBookName.applied(dbc, to: $0) }
        }
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
