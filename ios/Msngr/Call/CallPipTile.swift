import SwiftUI
import MsngrCore

/// The ongoing call folded into a floating capsule: the app is usable
/// underneath, the capsule keeps the call visible and a tap returns to the
/// full screen. It is dragged where the reader wants it and pinched larger or
/// smaller. Shown by MsngrApp while the call is minimized.
struct CallPipTile: View {
    @EnvironmentObject private var app: AppState

    private var state: CallState { app.callState }

    var body: some View {
        FloatingTile {
            Button {
                app.callMinimized = false
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "phone.fill")
                    statusText
                        .monospacedDigit()
                }
                .textRole(Theme.Text.callControlLabel)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color.green))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("call.pip")
        }
    }

    private var statusText: some View {
        Group {
            switch state.phase {
            case .active:
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(Self.duration(since: state.connectedAt))
                }
            case .ringing:
                Text("Incoming call")
            default:
                Text("Calling…")
            }
        }
    }

    private static func duration(since start: Double?) -> String {
        guard let start else { return "0:00" }
        let seconds = max(0, Int(Date().timeIntervalSince1970 - start))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
