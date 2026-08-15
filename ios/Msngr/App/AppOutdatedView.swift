import SwiftUI

/// Сборка отстала от того, с чем работает: сервер уже не обслуживает её версию
/// протокола или хранилище на устройстве записано более новой версией. И то и
/// другое — тупик, из которого приложение само не выходит, поэтому вместо
/// бесконечного «подключение…» показывается состояние.
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
                Text("Приложение устарело")
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
            return "Эта версия больше не работает. Установите обновление, чтобы продолжить переписку."
        case .storageAhead:
            return "Данные на этом устройстве открывает только более новая версия. Установите обновление, чтобы вернуться к переписке."
        }
    }

    /// Кнопка есть только там, где действие правда что-то меняет: хранилище
    /// новее сборки открывается заново с нуля. Устаревший протокол так не
    /// лечится, и кнопки там нет.
    private var startOverButton: some View {
        Button(role: .destructive) {
            confirmingStartOver = true
        } label: {
            Group {
                if busy { ProgressView().tint(.white) }
                else { Text("Начать заново").bold() }
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
        .confirmationDialog("Начать заново?", isPresented: $confirmingStartOver, titleVisibility: .visible) {
            Button("Начать заново", role: .destructive) {
                busy = true
                Task { await app.startOverOnCleanStorage() }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Переписка и ключи, которые хранились на этом устройстве, будут удалены.")
        }
    }
}
