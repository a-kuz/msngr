import SwiftUI
import MsngrCore

/// The user's active devices: the session list from the server, and revoking
/// access. Revoking the current device takes the same path as «Выйти»: the token
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
                                Label("Отозвать", systemImage: "xmark.circle")
                            }
                        }
                }
            } footer: {
                if loaded {
                    Text(sessions.count == 1
                         ? "Здесь появятся другие устройства, на которых вы войдёте в аккаунт."
                         : "Отзыв отключает устройство от аккаунта: сокет закрывается, пуши перестают приходить.")
                }
            }
            Section {
                NavigationLink {
                    AddDeviceView()
                } label: {
                    Label("Добавить устройство", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("sessions.add")
            } footer: {
                Text("Пароля нет: попасть в аккаунт с нового устройства можно только отсюда. Пока хотя бы одно устройство на руках, доступ не потерян.")
            }
        }
        .overlay {
            if !loaded {
                ProgressView()
            } else if loadFailed && sessions.isEmpty {
                ContentUnavailableView("Список недоступен", systemImage: "wifi.slash",
                                       description: Text("Проверьте соединение и потяните, чтобы обновить."))
            }
        }
        .refreshable { await load() }
        .navigationTitle("Устройства")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .confirmationDialog(dialogTitle(pendingRevoke),
                            isPresented: Binding(get: { pendingRevoke != nil },
                                                 set: { if !$0 { pendingRevoke = nil } }),
                            titleVisibility: .visible) {
            if let s = pendingRevoke {
                Button(s.current ? "Выйти" : "Отозвать", role: .destructive) {
                    Task { await revoke(s) }
                }
            }
            Button("Отмена", role: .cancel) { pendingRevoke = nil }
        } message: {
            if let s = pendingRevoke, s.current {
                Text("Переписка и ключи с этого устройства будут удалены.")
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
                Text(s.name ?? "Неизвестное устройство")
                    .font(.body)
                Text(Self.addedLabel(s.createdAtSeconds))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if busyDeviceId == s.deviceId {
                ProgressView()
            } else if s.current {
                Text("Это устройство")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func dialogTitle(_ s: APIClient.SessionDTO?) -> String {
        guard let s else { return "" }
        return s.current ? "Выйти на этом устройстве?" : "Отозвать «\(s.name ?? "устройство")»?"
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

    /// «Добавлено 15 августа 2026»; a session added today shows the time instead.
    static func addedLabel(_ ts: Double) -> String {
        guard ts > 0 else { return "Добавлено недавно" }
        let date = Date(timeIntervalSince1970: ts)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "ru_RU")
        if Calendar.current.isDateInToday(date) {
            fmt.dateFormat = "'сегодня в' HH:mm"
        } else {
            fmt.dateFormat = "d MMMM yyyy"
        }
        return "Добавлено " + fmt.string(from: date)
    }
}
