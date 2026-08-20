import SwiftUI
import MsngrCore

/// The user's active devices: the session list from the server, and revoking
/// access. Revoking the current device takes the same path as signing out: the token
/// is invalidated, local data is wiped, and the app returns to registration.
struct SessionsView: View {
    @EnvironmentObject var app: AppState
    @State private var sessions: [APIClient.SessionDTO] = []
    @State private var loaded = false
    @State private var loadFailed = false
    @State private var pendingRevoke: APIClient.SessionDTO?
    @State private var busyDeviceId: String?

    var body: some View {
        List {
            Section {
                ForEach(sessions) { s in
                    row(s)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingRevoke = s
                            } label: {
                                Label("Revoke", systemImage: "xmark.circle")
                            }
                        }
                }
            } footer: {
                if loaded {
                    Text(sessions.count == 1
                         ? "Other devices you log in on will appear here."
                         : "Revoking disconnects a device from the account: its connection closes and pushes stop.")
                }
            }
            Section {
                NavigationLink {
                    AddDeviceView()
                } label: {
                    Label("Add device", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("sessions.add")
            } footer: {
                Text("There is no password: a new device can only join the account from here. As long as one device is at hand, access is not lost.")
            }
        }
        .overlay {
            if !loaded {
                ProgressView()
            } else if loadFailed && sessions.isEmpty {
                ContentUnavailableView("List unavailable", systemImage: "wifi.slash",
                                       description: Text("Check the connection and pull to refresh."))
            }
        }
        .refreshable { await load() }
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .confirmationDialog(dialogTitle(pendingRevoke),
                            isPresented: Binding(get: { pendingRevoke != nil },
                                                 set: { if !$0 { pendingRevoke = nil } }),
                            titleVisibility: .visible) {
            if let s = pendingRevoke {
                Button(s.current ? "Log out" : "Revoke", role: .destructive) {
                    Task { await revoke(s) }
                }
            }
            Button("Cancel", role: .cancel) { pendingRevoke = nil }
        } message: {
            if let s = pendingRevoke, s.current {
                Text("Messages and keys on this device will be deleted.")
            }
        }
    }

    private func row(_ s: APIClient.SessionDTO) -> some View {
        HStack(spacing: 12) {
            Image(systemName: s.current ? "iphone" : "laptopcomputer.and.iphone")
                .font(Theme.glyph(20, max: 30))
                .foregroundStyle(Theme.accent)
                .frame(width: TypeScale.scaled(28, max: 40))
            VStack(alignment: .leading, spacing: 3) {
                Text(s.name ?? String(localized: "Unknown device"))
                    .font(.body)
                Text(Self.addedLabel(s.createdAtSeconds))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if busyDeviceId == s.deviceId {
                ProgressView()
            } else if s.current {
                Text("This device")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func dialogTitle(_ s: APIClient.SessionDTO?) -> String {
        guard let s else { return "" }
        return s.current
            ? String(localized: "Log out on this device?")
            : String(localized: "Revoke “\(s.name ?? String(localized: "device"))”?")
    }

    private func load() async {
        guard let api = app.api else { return }
        do {
            sessions = try await api.sessions()
            loadFailed = false
        } catch {
            loadFailed = true
        }
        loaded = true
    }

    private func revoke(_ s: APIClient.SessionDTO) async {
        pendingRevoke = nil
        guard let api = app.api else { return }
        if s.current {
            await app.logout()
            return
        }
        busyDeviceId = s.deviceId
        defer { busyDeviceId = nil }
        do {
            try await api.revokeSession(deviceId: s.deviceId)
            // the revoked device holds every group chain it was handed; the next
            // group message goes out on one it never saw
            try? app.e2ee?.rotateAllSenderKeys()
            sessions.removeAll { $0.deviceId == s.deviceId }
        } catch {
            await load()
        }
    }

    /// The "added on <date>" line; a session added today shows the time instead.
    static func addedLabel(_ ts: Double) -> String {
        guard ts > 0 else { return String(localized: "Added recently") }
        let date = Date(timeIntervalSince1970: ts)
        let fmt = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            fmt.dateFormat = "HH:mm"
            return String(localized: "Added today at \(fmt.string(from: date))")
        }
        fmt.setLocalizedDateFormatFromTemplate("dMMMMyyyy")
        return String(localized: "Added \(fmt.string(from: date))")
    }
}
