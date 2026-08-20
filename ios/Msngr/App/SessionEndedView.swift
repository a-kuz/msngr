import SwiftUI

/// The device was cut off from the account from another device. There is
/// nothing left to reconnect to, so instead of an endless connecting state
/// the screen shows a dead end whose only way out is registering again.
struct SessionEndedView: View {
    @EnvironmentObject var app: AppState
    @State private var busy = false

    var body: some View {
        ZStack {
            Theme.chatBackground.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "iphone.slash")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Session ended")
                    .font(.title2.bold())
                Text("This device's access to the account has been revoked. The messages and keys stored here are being deleted.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                Button {
                    busy = true
                    Task { await app.finishRevokedSession() }
                } label: {
                    if busy { ProgressView() }
                    // the start screen offers both: a new account and
                    // signing back in from a device still on this one
                    else { Text("Start over") }
                }
                .buttonStyle(.primaryAction)
                .disabled(busy)
                .accessibilityIdentifier("session.ended.restart")
                .padding(.horizontal, 32)
                .padding(.top, 8)
            }
        }
    }
}
