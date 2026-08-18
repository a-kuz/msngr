import SwiftUI
import GRDB
import MsngrCore

/// Changing the handle people find this account by. The server holds one
/// username per row under a unique index, so the statement that takes the new
/// one is the same statement that gives up the old.
struct UsernameView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Юзернейм", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("username.field")
            } footer: {
                if let error {
                    Text(error).foregroundStyle(.red)
                } else if let hint = AccountValidator.usernameHint(username) {
                    Text(hint)
                } else {
                    Text("По этому имени вас находят в поиске. Старое имя освободится сразу.")
                }
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    if busy { ProgressView() } else { Text("Сохранить") }
                }
                .buttonStyle(.primaryAction)
                .disabled(busy || !canSave)
                .accessibilityIdentifier("username.save")
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Юзернейм")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if username.isEmpty { username = app.session?.username ?? "" } }
        .onChange(of: username) { _, _ in error = nil }
    }

    private var canSave: Bool {
        AccountValidator.isValidUsername(username) && username != app.session?.username
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            try await app.api.updateUsername(username)
            // the handle is on screen in two places that do not come from the
            // server: the session file and this device's own row
            try? app.updateSessionUsername(username)
            if let id = app.session?.userId {
                try? await app.db.write { dbc in
                    try dbc.execute(sql: "UPDATE user SET username = ? WHERE id = ?",
                                    arguments: [username, id])
                }
            }
            dismiss()
        } catch let e as APIError {
            error = e.code == "username_taken" ? "Юзернейм занят" : "Не удалось сменить юзернейм"
        } catch {
            self.error = "Нет связи с сервером"
        }
    }
}
