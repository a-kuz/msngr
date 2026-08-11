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
                    TextField("Имя", text: $displayName)
                        .textFieldStyle(.roundedBorder)
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
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || !usernameValid)
                .padding(.horizontal, 32)
                Spacer()
                Spacer()
            }
        }
    }

    private var usernameValid: Bool {
        username.range(of: "^[a-zA-Z0-9_]{3,32}$", options: .regularExpression) != nil
    }

    private func register() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            // временная БД нужна до session: identity создаём в постоянной БД приложения
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let db = try AppDatabase.open(at: support.appendingPathComponent("msngr.sqlite"))
            let store = try IdentityStore(db: db, masterKeyProvider: KeychainMasterKey())
            let identity = try store.identity()
            let prekeys = try store.generatePrekeys(count: 100)

            let api = APIClient(baseURL: AppState.httpBase)
            let name = displayName.isEmpty ? username : displayName
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
            app.saveSession(Session(userId: reg.userId, deviceId: reg.deviceId,
                                    token: reg.token, username: username))
        } catch let e as APIError {
            error = e.code == "username_taken" ? "Юзернейм занят" : "Ошибка: \(e.code)"
        } catch {
            self.error = "Нет связи с сервером"
        }
    }
}
