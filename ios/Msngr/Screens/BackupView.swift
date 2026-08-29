import SwiftUI
import MsngrCore
import MsngrCrypto
import UniformTypeIdentifiers

/// A backup as a file: `BackupSeal` produces opaque encrypted bytes, and this
/// is only the wrapper `fileExporter`/`fileImporter` need to move them through
/// the share sheet and the Files picker. The recovery-code encryption and the
/// choice of what a backup carries live in MsngrCore/MsngrCrypto and know
/// nothing about how the bytes travel — a CloudKit transport would read and
/// write the same `SealedBackup` JSON without touching either.
struct BackupFile: FileDocument {
    static var readableContentTypes: [UTType] = [.data]
    static var writableContentTypes: [UTType] = [.data]
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Turning backup on, showing the recovery code once, and exporting.
///
/// iCloud (CloudKit) is the target storage named in the roadmap, but it needs
/// an Apple ID signed into the simulator/device to test at all; this screen
/// exports to a file instead, which `fileExporter` can hand to Files, AirDrop
/// or iCloud Drive without either this screen or `AccountBackup`/`BackupSeal`
/// knowing which one the user picked. Swapping in a CloudKit uploader later
/// changes only where the bytes this screen already has land.
struct BackupView: View {
    @EnvironmentObject var app: AppState

    private enum Stage: Equatable {
        case off
        case revealingCode(String)
        case on
    }

    @State private var stage: Stage = BackupStore.isEnabled ? .on : .off
    @State private var busy = false
    @State private var error: String?
    @State private var exportDocument: BackupFile?
    @State private var showExporter = false
    /// Set right before `showExporter`, read only once the export sheet
    /// reports success: "last backup" has to mean the file actually left this
    /// screen, not just that sealing it worked.
    @State private var pendingSize: Int64 = 0
    @State private var lastAt: Date? = BackupStore.lastBackupAt
    @State private var lastSize: Int64 = BackupStore.lastBackupSize

    var body: some View {
        List {
            switch stage {
            case .off:
                Section {
                    Text("A backup carries your chats, media and settings, encrypted on this device before anything leaves it. Restoring it on a new device does not carry your active conversations — those start fresh, the way a second device always does.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await turnOn() }
                    } label: {
                        if busy { ProgressView() } else { Text("Turn on backup") }
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("backup.turnOn")
                }
            case .revealingCode(let code):
                Section {
                    Text("Recovery code")
                        .font(.headline)
                    Text(BackupSeal.formatRecoveryCode(code))
                        .font(.system(.title3, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("backup.recoveryCode")
                    Text("This is the only way to open the backup on a new device. Nobody else can read it or hand it back to you — write it down now.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("I saved it") {
                        Task { await finishTurnOn(code: code) }
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("backup.codeSaved")
                }
            case .on:
                Section {
                    if let lastAt {
                        LabeledContent("Last backup", value: lastAt.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        Text("Not backed up yet on this device.")
                            .foregroundStyle(.secondary)
                    }
                    if lastSize > 0 {
                        LabeledContent("Size", value: SettingsView.sizeLabel(lastSize))
                    }
                    Button {
                        Task { await backUpNow() }
                    } label: {
                        if busy { ProgressView() } else { Text("Back up now") }
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("backup.now")
                } footer: {
                    Text("Each backup is exported as a file to save wherever you choose. It runs only when you ask.")
                }
                Section {
                    Button("Turn off backup", role: .destructive) {
                        BackupStore.isEnabled = false
                        stage = .off
                    }
                    .accessibilityIdentifier("backup.turnOff")
                } footer: {
                    Text("This only stops future backups on this device. A file you already saved elsewhere is not deleted.")
                }
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.footnote)
            }
        }
        .navigationTitle("Backup")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(isPresented: $showExporter, document: exportDocument,
                     contentType: .data, defaultFilename: defaultFilename) { result in
            switch result {
            case .success:
                lastAt = Date()
                lastSize = pendingSize
                BackupStore.lastBackupAt = lastAt
                BackupStore.lastBackupSize = lastSize
            case .failure(let e):
                self.error = e.localizedDescription
            }
        }
    }

    private var defaultFilename: String {
        "msngr-\(app.session?.username ?? "backup").msngrbackup"
    }

    private func turnOn() async {
        busy = true; error = nil
        defer { busy = false }
        let code = BackupSeal.generateRecoveryCode()
        BackupStore.sessionRecoveryCode = code
        stage = .revealingCode(code)
    }

    private func finishTurnOn(code: String) async {
        BackupStore.isEnabled = true
        stage = .on
        await backUpNow(code: code)
    }

    /// `code` is only ever non-nil right after `turnOn`, when the user has
    /// just seen it and it is still in memory; every later backup asks
    /// nothing of the user, because the recovery code was never stored.
    private func backUpNow(code: String? = nil) async {
        guard let session = app.session, let store = app.store, let db = app.db, let media = app.media
        else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let identity = try store.identity()
            let me = try? await db.read { dbc in try User.fetchOne(dbc, key: session.userId) }
            let payload = try await AccountBackup.buildPayload(
                db: db, media: media, userId: session.userId, username: session.username,
                displayName: (me ?? nil)?.displayName ?? session.username,
                identityDH: identity.dh.rawRepresentation.base64urlEncodedString(),
                identitySigning: identity.signing.rawRepresentation.base64urlEncodedString(),
                palette: ThemeStore.shared.palette.rawValue,
                showsMessageText: NotificationPreferences.showsMessageText(in: AppGroup.defaults))
            guard let recoveryCode = code ?? BackupStore.sessionRecoveryCode else {
                error = String(localized: "Recovery code not available in this session; turn backup off and on again.")
                return
            }
            let sealed = try BackupSeal.seal(payload, recoveryCode: recoveryCode)
            let data = try JSONEncoder().encode(sealed)
            exportDocument = BackupFile(data: data)
            pendingSize = Int64(data.count)
            showExporter = true
        } catch {
            self.error = String(localized: "Could not build the backup")
        }
    }
}

/// Whether backup is on, and when it last ran — the only state kept about a
/// backup on this device. The recovery code itself is never written here: it
/// is shown once, and this only remembers it for the rest of the screen's
/// session that showed it, so "Back up now" right after turning it on does
/// not ask for a code nobody has written down yet.
enum BackupStore {
    private static let enabledKey = "backup.enabled"
    private static let lastAtKey = "backup.lastAt"
    private static let lastSizeKey = "backup.lastSize"

    static var isEnabled: Bool {
        get { AppGroup.defaults.bool(forKey: enabledKey) }
        set { AppGroup.defaults.set(newValue, forKey: enabledKey) }
    }
    static var lastBackupAt: Date? {
        get { (AppGroup.defaults.object(forKey: lastAtKey) as? Double).map(Date.init(timeIntervalSince1970:)) }
        set { AppGroup.defaults.set(newValue?.timeIntervalSince1970, forKey: lastAtKey) }
    }
    static var lastBackupSize: Int64 {
        get { Int64(AppGroup.defaults.integer(forKey: lastSizeKey)) }
        set { AppGroup.defaults.set(Int(newValue), forKey: lastSizeKey) }
    }
    /// In-memory only, cleared on relaunch: the code the user just saw while
    /// this process is still alive, so this run's "Back up now" does not need
    /// it typed back in.
    static var sessionRecoveryCode: String?
}
