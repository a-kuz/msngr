import SwiftUI

/// Устройство отключили от аккаунта с другого устройства. Переподключаться
/// некуда, поэтому вместо бесконечного «подключение…» показывается тупик
/// с единственным выходом — регистрацией заново.
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
                Text("Сессия завершена")
                    .font(.title2.bold())
                Text("Доступ этого устройства к аккаунту отозван. Переписка и ключи, которые хранились здесь, удаляются.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                Button {
                    busy = true
                    Task { await app.finishRevokedSession() }
                } label: {
                    Group {
                        if busy { ProgressView().tint(.white) }
                        else { Text("Создать аккаунт заново").bold() }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(busy)
                .accessibilityIdentifier("session.ended.restart")
                .padding(.horizontal, 32)
                .padding(.top, 8)
            }
        }
    }
}
