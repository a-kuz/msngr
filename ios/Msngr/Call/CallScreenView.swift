import SwiftUI
import GRDB
import LiveKit
import MsngrCore
import MsngrCalls

/// The call, full screen over everything but the passcode: who, what phase,
/// and the few controls a call has. Shown while `AppState.callState` is not
/// idle; an ended call shows its outcome briefly and dismisses itself. A room
/// call shows everyone in it as a grid of tiles in place of the one avatar.
struct CallScreenView: View {
    @EnvironmentObject private var app: AppState
    @State private var peer: User?
    @State private var participantNames: [String: String] = [:]
    @State private var ownName = ""
    @State private var waitingName: String?
    @State private var heldName: String?
    @State private var transport: WebRTCTransport?
    @State private var roomSession: LiveKitRoomSession?
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
            if roomStageShown {
                // the controls keep the bottom of the screen
                roomStage
                    .padding(.bottom, 190)
                    .ignoresSafeArea()
            }
            VStack(spacing: 0) {
                if roomStageShown {
                    statusLine
                        .padding(.top, 100)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.black.opacity(0.3)).padding(.top, 100))
                    Spacer()
                } else {
                    Spacer()
                    if !remoteVideoShown {
                        AvatarView(name: peer?.displayName ?? "", avatarId: peer?.avatarId,
                                   glyph: state.isRoom && peer == nil ? "person.2.fill" : nil)
                            .frame(width: 104, height: 104)
                        Text(names)
                            .textRole(Theme.Text.callName)
                            .multilineTextAlignment(.center)
                            .padding(.top, 20)
                            .padding(.horizontal, 24)
                        statusLine
                            .padding(.top, 6)
                    }
                }
                Spacer()
                controls
                    .padding(.bottom, 56)
            }
            // in a room this device is the small floating tile: camera when
            // it is on, avatar when it is off. The others share the screen
            if roomStageShown {
                FloatingTile(margin: 14) {
                    selfTile
                        .frame(width: 108, height: 144)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(alignment: .bottomTrailing) {
                            if state.localVideo {
                                flipButton { roomSession?.switchCamera() }
                            }
                        }
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                }
                .padding(.top, 52)
            }
            if state.localVideo, !state.isRoom, let transport {
                FloatingTile(margin: 14) {
                    LocalVideoView(transport: transport)
                        .frame(width: 108, height: 144)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(alignment: .bottomTrailing) {
                            flipButton { transport.switchCamera() }
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
            roomSession = await app.callManager?.activeRoom() as? LiveKitRoomSession
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
            // pulling another person in: only on a standing call. A 1:1 call
            // moves into a room for it; a room takes as many as the SFU does
            if state.phase == .active {
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
            CallInvitePicker(exclude: Set([app.session?.userId, state.peerUserId].compactMap { $0 }
                                          + state.participants.map(\.userId))) { userId in
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
        .task(id: "\(state.peerUserId ?? "")|\(state.participants.map(\.userId).joined(separator: ","))|\(state.waitingCallerId ?? "")|\(state.heldPeerId ?? "")") {
            await loadPeer()
        }
        .accessibilityIdentifier("call.screen")
    }

    // MARK: - The room

    /// The stage stands in for the avatar once this device is in the room:
    /// while dialing it is empty, waiting for the first person.
    private var roomStageShown: Bool {
        guard state.isRoom else { return false }
        switch state.phase {
        case .dialing, .connecting, .active: return true
        case .idle, .ringing, .ended: return false
        }
    }

    /// Everyone else, sharing the whole screen in equal parts: one person
    /// fills it, two split it top and bottom, more go two to a row. Nobody
    /// yet leaves the stage to this device's own name and the status line.
    private var roomStage: some View {
        let rows = Self.stageRows(state.participants)
        return GeometryReader { geo in
            if rows.isEmpty {
                VStack(spacing: 12) {
                    AvatarView(name: ownName, avatarId: nil)
                        .frame(width: 104, height: 104)
                    Text(ownName)
                        .textRole(Theme.Text.callName)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 2) {
                            ForEach(row) { p in
                                tile(userId: p.userId, name: participantNames[p.userId] ?? "…",
                                     speaking: p.speaking, muted: p.muted, video: p.video,
                                     track: p.video ? roomSession?.videoTrack(for: p.userId) : nil)
                            }
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .accessibilityIdentifier("call.stage")
    }

    /// One person alone fills the stage, two take a row each, from three on
    /// they sit two to a row and an odd last one takes its row alone.
    static func stageRows(_ participants: [CallParticipant]) -> [[CallParticipant]] {
        switch participants.count {
        case 0: return []
        case 1, 2: return participants.map { [$0] }
        default: return stride(from: 0, to: participants.count, by: 2).map {
            Array(participants[$0..<min($0 + 2, participants.count)])
        }
        }
    }

    /// One person on the stage: their camera when it is on, their avatar and
    /// name when it is not, a ring while they speak, a glyph while muted.
    private func tile(userId: String, name: String, speaking: Bool, muted: Bool, video: Bool,
                      track: VideoTrack?) -> some View {
        ZStack {
            Color.black.opacity(0.25)
            if video, let track {
                RoomVideoView(track: track)
            } else {
                VStack(spacing: 10) {
                    AvatarView(name: name, avatarId: nil)
                        .frame(width: 84, height: 84)
                    Text(name)
                        .textRole(Theme.Text.callControlLabel)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                }
                .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                if muted {
                    Image(systemName: "mic.slash.fill")
                        .font(Theme.glyph(12, max: 15))
                }
                if video {
                    Text(name)
                        .textRole(Theme.Text.callControlLabel)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, muted || video ? 8 : 0)
            .padding(.vertical, muted || video ? 5 : 0)
            .background(Capsule().fill(.black.opacity(0.45)))
            .padding(10)
        }
        .overlay {
            Rectangle()
                .strokeBorder(Color.green, lineWidth: speaking ? 3 : 0)
                .animation(.easeInOut(duration: 0.15), value: speaking)
        }
        .clipped()
        .accessibilityIdentifier("call.tile.\(userId)")
    }

    /// This device in the corner: the camera when it is on, the avatar when
    /// it is off, the muted glyph over either.
    private var selfTile: some View {
        ZStack {
            Color.black.opacity(0.35)
            if state.localVideo, let track = roomSession?.localVideoTrack {
                RoomVideoView(track: track)
            } else {
                AvatarView(name: ownName, avatarId: nil)
                    .frame(width: 56, height: 56)
            }
        }
        .overlay(alignment: .topLeading) {
            if state.muted {
                Image(systemName: "mic.slash.fill")
                    .font(Theme.glyph(11, max: 14))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(Circle().fill(.black.opacity(0.45)))
                    .padding(6)
            }
        }
        .accessibilityIdentifier("call.tile.self")
    }

    private func flipButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
                .font(Theme.glyph(13, max: 17))
                .foregroundStyle(.white)
                .padding(6)
                .background(Circle().fill(.black.opacity(0.35)))
        }
        .padding(4)
        .accessibilityIdentifier("call.flipCamera")
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
            // a room call is left, not held: the trade is the only move there
            if !state.isRoom {
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
        !state.isRoom && state.remoteVideo && (state.phase == .active || state.phase == .connecting)
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
                Text(state.isRoom ? "Incoming group call"
                     : state.remoteVideo ? "Incoming video call" : "Incoming call")
            case .connecting:
                Text("Connecting…")
            case .active:
                if state.remoteHold {
                    Text("On hold")
                } else if state.reconnecting {
                    Text("Connecting…")
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

    /// Who is on the other side: the peer of a 1:1 call, the inviter of a
    /// room invite while it rings.
    private var names: String {
        if state.isRoom, peer == nil { return String(localized: "Group call") }
        return peer?.displayName ?? "…"
    }

    private func loadPeer() async {
        guard let db = app.db else {
            peer = nil
            participantNames = [:]
            waitingName = nil
            heldName = nil
            return
        }
        let peerId = state.peerUserId
        let participantIds = state.participants.map(\.userId)
        let waitingId = state.waitingCallerId
        let heldId = state.heldPeerId
        let ownId = app.session?.userId
        let loaded = try? await db.read { dbc -> (User?, [String: String], String?, String?, String) in
            func name(_ userId: String) throws -> String? {
                try User.fetchOne(dbc, key: userId)
                    .map { try ContactBookName.applied(dbc, to: $0).displayName }
            }
            let peer = try peerId.flatMap { try User.fetchOne(dbc, key: $0) }
                .map { try ContactBookName.applied(dbc, to: $0) }
            var names: [String: String] = [:]
            for id in participantIds {
                if let n = try name(id) { names[id] = n }
            }
            let own = try ownId.flatMap { try User.fetchOne(dbc, key: $0)?.displayName } ?? ""
            return (peer, names, try waitingId.flatMap { try name($0) },
                    try heldId.flatMap { try name($0) }, own)
        }
        peer = loaded?.0
        participantNames = loaded?.1 ?? [:]
        waitingName = loaded?.2
        heldName = loaded?.3
        ownName = loaded?.4 ?? ""
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
