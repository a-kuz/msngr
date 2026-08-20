import SwiftUI

/// The build fell behind what it works with: either the server no longer
/// serves its protocol version, or the storage on the device was written by a
/// newer build. Neither is something the app can get out of on its own, so it
/// shows the state instead of an endless connecting spinner.
struct AppOutdatedView: View {
    @EnvironmentObject var app: AppState
    let reason: OutdatedBuild
    @State private var confirmingStartOver = false
    @State private var busy = false

    var body: some View {
        ZStack {
            Theme.chatBackground.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "arrow.up.circle")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("App out of date")
                    .font(.title2.bold())
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                if reason == .storageAhead { startOverButton }
            }
        }
        .accessibilityIdentifier("app.outdated")
    }

    private var detail: String {
        switch reason {
        case .protocolRefused:
            return String(localized: "This version no longer works. Install the update to keep messaging.")
        case .storageAhead:
            return String(localized: "The data on this device opens only with a newer version. Install the update to get back to your messages.")
        }
    }

    /// The button is here only because the action really changes something:
    /// storage newer than the build can be reopened from scratch. An outdated
    /// protocol is not cured that way, so that case gets no button.
    private var startOverButton: some View {
        Button(role: .destructive) {
            confirmingStartOver = true
        } label: {
            Group {
                if busy { ProgressView().tint(.white) }
                else { Text("Start over").bold() }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Color.red, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(busy)
        .accessibilityIdentifier("app.outdated.startOver")
        .padding(.horizontal, 32)
        .padding(.top, 8)
        .confirmationDialog("Start over?", isPresented: $confirmingStartOver, titleVisibility: .visible) {
            Button("Start over", role: .destructive) {
                busy = true
                Task { await app.startOverOnCleanStorage() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The messages and keys stored on this device will be deleted.")
        }
    }
}
