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
        .navigationTitle("Добавить устройство")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var entry: some View {
        VStack(spacing: 20) {
            Text("На новом устройстве откройте «Войти по коду» и введите показанный там код сюда.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            TextField("Код", text: $code)
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
                Group {
                    if busy { ProgressView().tint(.white) } else { Text("Далее").bold() }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 48)
                .background(Theme.accent.opacity(codeValid ? 1 : 0.4),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
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
            Text(found.device.name ?? "Новое устройство").font(.title3.bold())
            Text("Устройство получит доступ к аккаунту и сможет читать и отправлять новые сообщения. Старая переписка на него не переносится.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Button {
                Task { await approve(found) }
            } label: {
                Group {
                    if busy { ProgressView().tint(.white) } else { Text("Подтвердить").bold() }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 48)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(busy)
            .accessibilityIdentifier("adddevice.approve")
            Button("Отмена") { self.found = nil; self.error = nil }
                .font(.footnote)
        }
    }

    private var done: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text("Устройство добавлено").font(.title3.bold())
            Text("Оно появится в списке устройств. Отозвать доступ можно там же.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Готово") { dismiss() }
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
            self.error = "Нет связи с сервером"
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
            self.error = "Нет связи с сервером"
        }
    }

    private func message(for code: String) -> String {
        switch code {
        case "provision_not_found": return "Код не найден. Проверьте, что он введён полностью."
        case "provision_expired": return "Код истёк. Попросите показать новый."
        case "provision_claimed": return "Этот код уже использован."
        default: return "Ошибка: \(code)"
        }
    }
}
