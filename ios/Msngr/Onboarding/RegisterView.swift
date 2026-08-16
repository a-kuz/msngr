import SwiftUI
import GRDB
import MsngrCore

/// Регистрация: username + имя; ключи генерируются на устройстве.
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
                Text("Сквозное шифрование. Ключи создаются на этом устройстве.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                VStack(spacing: 12) {
                    TextField("Юзернейм (a-z, 0-9, _)", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("reg.username")
                    TextField("Имя", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("reg.displayName")
                    if !trimmedName.isEmpty && !nameValid {
                        Text("Имя — минимум 3 символа")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 32)

                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }

                Button {
                    Task { await register() }
                } label: {
                    Group {
                        if busy { ProgressView().tint(.white) }
                        else { Text("Создать аккаунт").bold() }
                    }
                    .foregroundStyle(.white.opacity(formValid ? 1 : 0.85))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Theme.accent.opacity(formValid ? 1 : 0.4),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(busy || !formValid)
                .accessibilityIdentifier("reg.submit")
                .padding(.horizontal, 32)
                Spacer()
                Spacer()
            }
        }
    }

    private var usernameValid: Bool { RegistrationValidator.isValidUsername(username) }

    private var trimmedName: String { RegistrationValidator.trimmedName(displayName) }

    private var nameValid: Bool { RegistrationValidator.isValidName(displayName) }

    private var formValid: Bool { usernameValid && nameValid }

    private func register() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            // временная БД нужна до session: identity создаём в постоянной БД приложения
            let storage = AppState.storage
            // a new account starts from empty storage: whatever the container
            // holds belongs to somebody else and is dropped before the identity
            // keys are generated into the same database
            let db = try StorageOwnership.openOwned(at: storage, expectedUserId: nil,
                                                    wipe: { _ in AppState.wipeLocalData() })
            let store = try IdentityStore(db: db, masterKeyProvider: SharedFileMasterKey(location: storage))
            let identity = try store.identity()
            let prekeys = try store.generatePrekeys(count: 100)

            let api = APIClient(baseURL: AppState.httpBase)
            let name = trimmedName
            let reg = try await api.register(.init(
                username: username, displayName: name, deviceName: UIDevice.current.name,
                identityKey: identity.dh.publicKey.rawRepresentation.base64urlEncodedString(),
                identitySignKey: identity.signing.publicKey.rawRepresentation.base64urlEncodedString(),
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
                MsngrLog.session.error("не удалось сохранить сессию: \(error)")
                self.error = "Не удалось сохранить сессию на устройстве"
                return
            }
        } catch let e as APIError {
            error = e.code == "username_taken" ? "Юзернейм занят" : "Ошибка: \(e.code)"
        } catch {
            self.error = "Нет связи с сервером"
        }
    }
}
