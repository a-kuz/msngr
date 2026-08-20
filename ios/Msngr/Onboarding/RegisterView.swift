import SwiftUI
import GRDB
import MsngrCore

/// Registration: username plus display name; the keys are generated on the device.
struct RegisterView: View {
    @EnvironmentObject var app: AppState
    @State private var username = ""
    @State private var displayName = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "message.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text("Msngr")
                    .font(.largeTitle.bold())
                Text("End-to-end encrypted. The keys are created on this device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                VStack(spacing: 12) {
                    TextField("Username (a-z, 0-9, _)", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("reg.username")
                    // the button says nothing about why it is off, so each
                    // field says it for itself, and only once it is wrong
                    if let hint = AccountValidator.usernameHint(username) {
                        fieldHint(hint, id: "reg.usernameHint")
                    }
                    TextField("Name", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("reg.displayName")
                    if let hint = AccountValidator.nameHint(displayName) {
                        fieldHint(hint, id: "reg.displayNameHint")
                    }
                }
                .padding(.horizontal, 32)

                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }

                Button {
                    Task { await register() }
                } label: {
                    if busy { ProgressView() } else { Text("Create account") }
                }
                .buttonStyle(.primaryAction)
                .disabled(busy || !formValid)
                .accessibilityIdentifier("reg.submit")
                .padding(.horizontal, 32)

                // there is no password to log in with: an account is reached
                // again only from a device already on it
                NavigationLink {
                    LinkDeviceView()
                } label: {
                    Text("Already have an account — log in by code")
                        .font(.footnote)
                }
                .accessibilityIdentifier("reg.link")
                Spacer()
                Spacer()
            }
        }
    }

    private func fieldHint(_ text: String, id: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(id)
    }

    private var usernameValid: Bool { AccountValidator.isValidUsername(username) }

    private var trimmedName: String { AccountValidator.trimmedName(displayName) }

    private var nameValid: Bool { AccountValidator.isValidName(displayName) }

    private var formValid: Bool { usernameValid && nameValid }

    private func register() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            // the identity is generated into the app's permanent database, the
            // one that outlives registration, not a temporary one
            let storage = AppState.storage
            // a new account starts from empty storage: whatever the container
            // holds belongs to somebody else and is dropped before the identity
            // keys are generated into the same database
            let db = try StorageOwnership.openOwned(at: storage, expectedUserId: nil,
                                                    wipe: { _ in AppState.wipeLocalData() })
            let store = try IdentityStore(db: db, masterKeyProvider: SharedFileMasterKey(location: storage))
            let identity = try store.identity()
            let prekeys = try store.generatePrekeys(count: 100)

            let api = AppNet.client()
            let name = trimmedName
            let reg = try await api.register(.init(
                username: username, displayName: name, deviceName: UIDevice.current.name,
                identityKey: identity.dh.publicKey.rawRepresentation.base64urlEncodedString(),
                identitySignKey: identity.signing.publicKey.rawRepresentation.base64urlEncodedString(),
                identityKeySig: try identity.dhSignature.base64urlEncodedString(),
                signedPrekey: .init(id: prekeys.signedPrekey.id,
                                    key: prekeys.signedPrekey.key.publicKey.rawRepresentation.base64urlEncodedString(),
                                    sig: prekeys.signedPrekey.signature.base64urlEncodedString()),
                oneTimePrekeys: prekeys.oneTime.map {
                    .init(id: $0.id, key: $0.key.publicKey.rawRepresentation.base64urlEncodedString())
                },
                phoneHash: nil))
            let session = Session(userId: reg.userId, deviceId: reg.deviceId,
                                  token: reg.token, username: username)
            // the storage is only known to be owned once the account exists
            try StorageOwnership.stamp(db, userId: reg.userId)
            do {
                try app.saveSession(session)
            } catch {
                MsngrLog.session.error("failed to save the session: \(error)")
                self.error = String(localized: "Could not save the session on this device")
                return
            }
        } catch let e as APIError {
            MsngrLog.session.error("registration refused: \(e.code)")
            error = e.code == "username_taken" ? String(localized: "Username is taken") : String(localized: "Could not create the account")
        } catch {
            self.error = String(localized: "No connection to the server")
        }
    }
}
