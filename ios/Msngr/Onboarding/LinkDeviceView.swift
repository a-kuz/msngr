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
        /// the history the approving device packed is being downloaded and written
        case movingHistory
        case failed(String)
    }

    @State private var stage: Stage = .starting
    @State private var pending: DeviceLink.Pending?
    @State private var bundle: Provisioning.Bundle?
    @State private var secondsLeft = 0

    private let api = AppNet.client()

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
                    Text("Setting up this device…").font(.footnote).foregroundStyle(.secondary)
                }
            case .movingHistory:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Moving the history to this device…").font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("link.history")
                }
            case .failed(let message):
                failed(message)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Log in by code")
        .navigationBarTitleDisplayMode(.inline)
        .task { await start() }
        .onDisappear { cancelPending() }
    }

    private var waiting: some View {
        VStack(spacing: 20) {
            Text("On a device already logged in, open:\nSettings → Devices → Add device\nand enter this code there.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(DeviceLink.formatCode(pending?.code ?? ""))
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .kerning(2)
                .accessibilityIdentifier("link.code")
            // the same code as a picture: the approving device reads it from
            // its camera or from a photo instead of typing eight characters
            if let code = pending?.code, let qr = QRCode.image(QRCode.linkPayload(code: code)) {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180, height: 180)
                    .padding(8)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("link.qr")
                    .accessibilityLabel(Text("QR code with the login code"))
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(secondsLeft > 0 ? "Waiting for confirmation · \(secondsLeft) s" : "Waiting for confirmation")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text("Your chats and their history move to this device once the login is confirmed.")
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
            Text("Log in as @\(username)?").font(.title3.bold())
            Text(displayName).font(.body).foregroundStyle(.secondary)
            Text("If this is not your account, cancel the login.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await finish() }
            } label: {
                Text("Log in")
            }
            .buttonStyle(.primaryAction)
            .accessibilityIdentifier("link.confirm")
            Button("Cancel") { cancelPending(); dismiss() }
                .font(.footnote)
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 16) {
            Text(message).font(.body).multilineTextAlignment(.center)
            Button("Try again") { Task { await start() } }
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
            stage = .failed(String(localized: "Could not reach the server"))
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
        stage = .failed(String(localized: "The code is no longer valid. Start over."))
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
            let linked = AppNet.client(token: claimed.token)
            // the history the approving device packed comes first, the rows
            // and the media both, so the chats open on what was said before
            // this device existed; a blob that cannot be fetched leaves the
            // account linked without its past
            if let history = bundle.history {
                stage = .movingHistory
                let media = MediaManager(api: linked,
                                         cacheDir: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                                             .appendingPathComponent("media"),
                                         pendingDir: storage.pendingMediaDir)
                if let payload = try? await HistoryTransfer.unpack(history, media: media) {
                    try await AccountBackup.apply(payload, db: db, media: media)
                    if let palette = payload.palette {
                        UserDefaults.standard.set(palette, forKey: "palette")
                    }
                    if let showsMessageText = payload.showsMessageText {
                        NotificationPreferences.setShowsMessageText(showsMessageText, in: AppGroup.defaults)
                    }
                }
            }
            // the chat list is written before the engine ever opens a socket,
            // so the first sync names the end of each journal instead of asking
            // for all of it; what the history brought stays below that mark
            let snapshot = try await linked.chatsSnapshot()
            try await db.write { dbc in
                try DeviceLink.primeChats(dbc, snapshot: snapshot, ownUserId: claimed.userId)
            }
            try StorageOwnership.stamp(db, userId: claimed.userId)
            try app.saveSession(Session(userId: claimed.userId, deviceId: claimed.deviceId,
                                        token: claimed.token, username: bundle.username))
        } catch DeviceLink.Failure.accountMismatch {
            AppState.wipeLocalData()
            stage = .failed(String(localized: "The code was approved from a different account. Start over."))
        } catch let e as APIError {
            stage = .failed(e.code == "identity_mismatch"
                            ? String(localized: "The account keys did not match. Start over.")
                            : String(localized: "Could not log in: \(e.code)"))
        } catch {
            stage = .failed(String(localized: "Could not log in on this device"))
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
