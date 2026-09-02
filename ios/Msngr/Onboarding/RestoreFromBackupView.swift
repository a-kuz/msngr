import GRDB
import MsngrCore
import MsngrCrypto
import SwiftUI
import UniformTypeIdentifiers

/// Restoring an account from a backup file, on a device with no account yet.
///
/// The file is opaque to the server and to Files/AirDrop/iCloud Drive alike;
/// only the recovery code opens it, and it never leaves this device. Claiming
/// the account signs the server's nonce with the identity key the backup
/// carries (`AccountRestore.claim`) — proof of possession stands in for the
/// live-device approval `LinkDeviceView` uses instead.
struct RestoreFromBackupView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    private enum Stage: Equatable {
        case pickFile
        case enterCode(fileName: String)
        case restoring
        case failed(String)
    }

    @State private var stage: Stage = .pickFile
    @State private var showImporter = false
    @State private var pickedData: Data?
    @State private var recoveryCode = ""
    /// The file itself says how it was sealed: v1 asks for the recovery code,
    /// v2 for the password the user picked.
    @State private var sealedWithPassphrase = false
    /// An Apple ID is signed in: the backup iCloud holds for it can be offered.
    @State private var cloudAvailable = false

    var body: some View {
        VStack(spacing: 24) {
            switch stage {
            case .pickFile:
                pickFile
            case .enterCode(let fileName):
                enterCode(fileName: fileName)
            case .restoring:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Restoring your account…").font(.footnote).foregroundStyle(.secondary)
                }
            case .failed(let message):
                failed(message)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Restore from backup")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url):
                loadFile(url)
            case .failure(let e):
                stage = .failed(e.localizedDescription)
            }
        }
    }

    private var pickFile: some View {
        VStack(spacing: 20) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 56))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text("Choose the backup file you saved, then enter its recovery code.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Choose file…") { showImporter = true }
                .buttonStyle(.primaryAction)
                .accessibilityIdentifier("restore.pickFile")
            // the backup iCloud holds for this Apple ID, opened with the key
            // the iCloud Keychain carried over: nothing to type
            if cloudAvailable {
                Button("Restore from iCloud") { Task { await restoreFromCloud() } }
                    .accessibilityIdentifier("restore.cloud")
            }
        }
        .task { cloudAvailable = await CloudBackup.accountAvailable() }
    }

    private func restoreFromCloud() async {
        stage = .restoring
        do {
            let backups = try await CloudBackup.fetchAll()
            guard let newest = backups.first else {
                stage = .failed(String(localized: "No iCloud backup for this Apple ID."))
                return
            }
            guard newest.sealed.v == 3, let key = try CloudBackupKey.read(userId: newest.userId) else {
                stage = .failed(String(localized: "The key to this backup has not reached this device's iCloud Keychain yet."))
                return
            }
            let payload = try BackupSeal.open(newest.sealed, deviceKey: key, as: BackupPayload.self)
            await restore(payload: payload)
        } catch {
            stage = .failed(String(localized: "Could not reach iCloud"))
        }
    }

    private func enterCode(fileName: String) -> some View {
        VStack(spacing: 16) {
            Text(fileName).font(.footnote).foregroundStyle(.secondary)
            if sealedWithPassphrase {
                SecureField("Backup password", text: $recoveryCode)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("restore.code")
            } else {
                TextField("Recovery code", text: $recoveryCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("restore.code")
            }
            Button("Restore") {
                Task { await restore() }
            }
            .buttonStyle(.primaryAction)
            .disabled(sealedWithPassphrase
                      ? BackupSeal.normalizePassphrase(recoveryCode).isEmpty
                      : BackupSeal.normalizeRecoveryCode(recoveryCode).isEmpty)
            .accessibilityIdentifier("restore.submit")
            Button("Cancel") { dismiss() }
                .font(.footnote)
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 16) {
            Text(message).font(.body).multilineTextAlignment(.center)
            Button("Try again") { stage = .pickFile; pickedData = nil; recoveryCode = "" }
        }
    }

    private func loadFile(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            stage = .failed(String(localized: "Could not open the file"))
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let data = try Data(contentsOf: url)
            pickedData = data
            let sealed = try? JSONDecoder().decode(BackupSeal.SealedBackup.self, from: data)
            sealedWithPassphrase = sealed?.v == 2
            stage = .enterCode(fileName: url.lastPathComponent)
        } catch {
            stage = .failed(String(localized: "Could not read the file"))
        }
    }

    private func restore() async {
        guard let pickedData else { return }
        stage = .restoring
        let payload: BackupPayload
        do {
            let sealed = try JSONDecoder().decode(BackupSeal.SealedBackup.self, from: pickedData)
            payload = try BackupSeal.open(sealed, recoveryCode: recoveryCode, as: BackupPayload.self)
        } catch {
            stage = .failed(String(localized: "That recovery code does not open this backup."))
            return
        }
        await restore(payload: payload)
    }

    /// The account out of an opened payload, whichever way it was opened: the
    /// claim first, the rows after it.
    private func restore(payload: BackupPayload) async {
        do {
            // an incoming account replaces whatever this container held
            let storage = AppState.storage
            let db = try StorageOwnership.openOwned(at: storage, expectedUserId: nil,
                                                    wipe: { _ in AppState.wipeLocalData() })
            let store = try IdentityStore(db: db, masterKeyProvider: SharedFileMasterKey(location: storage))
            let media = MediaManager(api: AppNet.client(),
                                     cacheDir: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                                         .appendingPathComponent("media"),
                                     pendingDir: storage.pendingMediaDir)

            let claimed = try await AccountRestore.claim(api: AppNet.client(), payload: payload,
                                                         store: store, deviceName: UIDevice.current.name)

            // the rows and the media cache go in after the claim: adopting the
            // identity above is what proved this device may hold this account's
            // data at all, and a claim that failed leaves nothing written
            try await AccountBackup.apply(payload, db: db, media: media)
            if let palette = payload.palette {
                UserDefaults.standard.set(palette, forKey: "palette")
            }
            if let showsMessageText = payload.showsMessageText {
                NotificationPreferences.setShowsMessageText(showsMessageText, in: AppGroup.defaults)
            }

            try StorageOwnership.stamp(db, userId: claimed.userId)
            try app.saveSession(Session(userId: claimed.userId, deviceId: claimed.deviceId,
                                        token: claimed.token, username: payload.username))
        } catch AccountRestore.Failure.accountMismatch {
            AppState.wipeLocalData()
            stage = .failed(String(localized: "The recovery code opened an account that does not match. Start over."))
        } catch BackupSeal.Failure.decryptionFailed, BackupSeal.Failure.badFormat {
            stage = .failed(String(localized: "That recovery code does not open this backup."))
        } catch let e as APIError {
            stage = .failed(e.code == "account_not_found"
                            ? String(localized: "No account matches this backup.")
                            : String(localized: "Could not restore: \(e.code)"))
        } catch {
            stage = .failed(String(localized: "Could not restore this backup"))
        }
    }
}
