import GRDB
import MsngrCore
import MsngrCrypto
import SwiftUI

/// Signing in on a device that has no account yet.
///
/// This screen shows a code and waits. The account arrives sealed to a key that
/// never leaves this device, and nothing is written to disk until its owner has
/// looked at the account name and said it is theirs.
struct LinkDeviceView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    private enum Stage: Equatable {
        case starting
        case waiting
        case confirming(username: String, displayName: String)
        case finishing
        case failed(String)
    }

    @State private var stage: Stage = .starting
    @State private var pending: DeviceLink.Pending?
    @State private var bundle: Provisioning.Bundle?
    @State private var secondsLeft = 0

    private let api = APIClient(baseURL: AppState.httpBase)

    var body: some View {
        VStack(spacing: 24) {
            switch stage {
            case .starting:
                ProgressView()
            case .waiting:
                waiting
            case .confirming(let username, let displayName):
                confirming(username: username, displayName: displayName)
            case .finishing:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Настраиваем устройство…").font(.footnote).foregroundStyle(.secondary)
                }
            case .failed(let message):
                failed(message)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Вход по коду")
        .navigationBarTitleDisplayMode(.inline)
        .task { await start() }
        .onDisappear { cancelPending() }
    }

    private var waiting: some View {
        VStack(spacing: 20) {
            Text("Откройте на устройстве, где уже вошли:\nНастройки → Устройства → Добавить устройство\nи введите этот код.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(DeviceLink.formatCode(pending?.code ?? ""))
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .kerning(2)
                .accessibilityIdentifier("link.code")
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(secondsLeft > 0 ? "Ждём подтверждения · \(secondsLeft) с" : "Ждём подтверждения")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text("История переписки на это устройство не переносится: старые сообщения останутся только там, где вы их читали.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func confirming(username: String, displayName: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 56))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text("Войти как @\(username)?").font(.title3.bold())
            Text(displayName).font(.body).foregroundStyle(.secondary)
            Text("Если это не ваш аккаунт, отмените вход.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await finish() }
            } label: {
                Text("Войти").bold()
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .accessibilityIdentifier("link.confirm")
            Button("Отмена") { cancelPending(); dismiss() }
                .font(.footnote)
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 16) {
            Text(message).font(.body).multilineTextAlignment(.center)
            Button("Попробовать снова") { Task { await start() } }
        }
    }

    // MARK: - Flow

    private func start() async {
        stage = .starting
        bundle = nil
        do {
            let started = try await DeviceLink.begin(
                api: api, deviceName: UIDevice.current.name, platform: "ios")
            pending = started
            secondsLeft = Int(started.expiresIn)
            stage = .waiting
            await waitForApproval(started)
        } catch {
            stage = .failed("Не удалось связаться с сервером")
        }
    }

    /// Polls the session until its owner approves it or it runs out. The wait is
    /// bounded by the session's own life, so a code left on screen stops being
    /// one rather than hanging around.
    private func waitForApproval(_ started: DeviceLink.Pending) async {
        while secondsLeft > 0 {
            try? await Task.sleep(for: .milliseconds(1500))
            if Task.isCancelled { return }
            guard case .waiting = stage else { return }
            secondsLeft = max(0, secondsLeft - 2)
            do {
                if let opened = try await DeviceLink.poll(api: api, pending: started) {
                    bundle = opened
                    stage = .confirming(username: opened.username, displayName: opened.displayName)
                    return
                }
            } catch let e as APIError where e.code == "provision_expired" {
                break
            } catch {
                // a poll that did not land is one poll; the session outlives it
            }
        }
        stage = .failed("Код больше не действует. Начните заново.")
    }

    private func finish() async {
        guard let pending, let bundle else { return }
        stage = .finishing
        do {
            let storage = AppState.storage
            // linking is an account arriving on this device: whatever the
            // container holds belongs to somebody else and goes before the
            // identity is written into the same database
            let db = try StorageOwnership.openOwned(at: storage, expectedUserId: nil,
                                                    wipe: { _ in AppState.wipeLocalData() })
            let store = try IdentityStore(db: db,
                                          masterKeyProvider: SharedFileMasterKey(location: storage))
            let claimed = try await DeviceLink.claim(api: api, pending: pending, bundle: bundle,
                                                     store: store,
                                                     deviceName: UIDevice.current.name)
            // the chat list comes over, the history does not: every chat starts
            // at the end it stands at now
            let linked = APIClient(baseURL: AppState.httpBase, token: claimed.token)
            if let snapshot = try? await linked.chatsSnapshot() {
                let ends = snapshot.chats.map { ($0.state.chatId, $0.state.lastSeq) }
                try await db.write { dbc in try DeviceLink.startChatsFromNow(dbc, chats: ends) }
            }
            try StorageOwnership.stamp(db, userId: claimed.userId)
            try app.saveSession(Session(userId: claimed.userId, deviceId: claimed.deviceId,
                                        token: claimed.token, username: bundle.username))
        } catch DeviceLink.Failure.accountMismatch {
            AppState.wipeLocalData()
            stage = .failed("Код подтвердили с чужого аккаунта. Начните заново.")
        } catch let e as APIError {
            stage = .failed(e.code == "identity_mismatch"
                            ? "Ключи аккаунта не совпали. Начните заново."
                            : "Не удалось войти: \(e.code)")
        } catch {
            stage = .failed("Не удалось войти на этом устройстве")
        }
    }

    /// A screen left behind takes its session with it: an unclaimed code should
    /// not stay approvable after nobody is waiting on it.
    private func cancelPending() {
        guard let pending, bundle == nil else { return }
        self.pending = nil
        Task { try? await api.provisionCancel(pending.provisionId,
                                              provisionToken: pending.provisionToken) }
    }
}
