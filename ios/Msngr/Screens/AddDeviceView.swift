import MsngrCore
import SwiftUI

/// Letting another device onto the account from one that is already on it.
///
/// Approving hands over the account's identity keys, so the screen says so and
/// asks twice: once for the code, once for the device the code belongs to.
struct AddDeviceView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var found: APIClient.ProvisionLookupResponse?
    @State private var busy = false
    @State private var error: String?
    @State private var approved = false

    var body: some View {
        VStack(spacing: 24) {
            if approved {
                done
            } else if let found {
                confirm(found)
            } else {
                entry
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 32)
        .navigationTitle("Add device")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var entry: some View {
        VStack(spacing: 20) {
            Text("On the new device open “Log in by code” and enter the code it shows here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            TextField("Code", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .multilineTextAlignment(.center)
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("adddevice.code")
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Button {
                Task { await lookup() }
            } label: {
                if busy { ProgressView() } else { Text("Next") }
            }
            .buttonStyle(.primaryAction)
            .disabled(busy || !codeValid)
            .accessibilityIdentifier("adddevice.next")
        }
    }

    private func confirm(_ found: APIClient.ProvisionLookupResponse) -> some View {
        VStack(spacing: 20) {
            Image(systemName: found.device.platform == "macos" ? "laptopcomputer" : "iphone")
                .font(.system(size: 56))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text(found.device.name ?? String(localized: "New device")).font(.title3.bold())
            Text("The device gets access to the account and can read and send new messages. Old history does not move to it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Button {
                Task { await approve(found) }
            } label: {
                if busy { ProgressView() } else { Text("Confirm") }
            }
            .buttonStyle(.primaryAction)
            .disabled(busy)
            .accessibilityIdentifier("adddevice.approve")
            Button("Cancel") { self.found = nil; self.error = nil }
                .font(.footnote)
        }
    }

    private var done: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text("Device added").font(.title3.bold())
            Text("It will appear in the device list. Access can be revoked there too.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Done") { dismiss() }
        }
    }

    private var codeValid: Bool { DeviceLink.normalizeCode(code).count == 8 }

    private func lookup() async {
        guard let api = app.api else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            found = try await api.provisionLookup(code: DeviceLink.normalizeCode(code))
        } catch let e as APIError {
            error = message(for: e.code)
        } catch {
            self.error = String(localized: "No connection to the server")
        }
    }

    private func approve(_ found: APIClient.ProvisionLookupResponse) async {
        guard let api = app.api, let store = app.store, let session = app.session else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let me = try await api.me()
            try await DeviceLink.approve(api: api, lookup: found, identity: try store.identity(),
                                         userId: session.userId, username: me.user.username,
                                         displayName: me.user.display_name)
            approved = true
        } catch let e as APIError {
            error = message(for: e.code)
            if e.code != "http_0" { self.found = nil }
        } catch {
            self.error = String(localized: "No connection to the server")
        }
    }

    private func message(for code: String) -> String {
        switch code {
        case "provision_not_found": return String(localized: "Code not found. Check that it is entered in full.")
        case "provision_expired": return String(localized: "The code has expired. Ask for a new one.")
        case "provision_claimed": return String(localized: "This code has already been used.")
        default: return String(localized: "Error: \(code)")
        }
    }
}
