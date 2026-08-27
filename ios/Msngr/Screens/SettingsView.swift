import SwiftUI
import PhotosUI
import MsngrCore

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var theme = ThemeStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var bio = ""
    @State private var avatarItem: PhotosPickerItem?
    @State private var me: User?
    @State private var showPinSetup = false
    @State private var pinEnabled = PinStore.hasPin()
    @State private var biometrics = PinStore.biometricsEnabled()
    @State private var showsMessageText = NotificationPreferences.showsMessageText(in: AppGroup.defaults)
    @State private var showLogoutConfirm = false
    /// the media cache size shown next to the clear button; the label re-renders
    /// only when this state moves, so the clear writes the new size back into it
    @State private var cacheSize: Int64 = 0
    @State private var uploadingAvatar = false
    @State private var nameError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        PhotosPicker(selection: $avatarItem, matching: .images) {
                            AvatarView(name: me?.displayName ?? "", avatarId: me?.avatarId)
                                .frame(width: 66, height: 66)
                                .overlay(alignment: .bottomTrailing) {
                                    // Badge geometry belongs to the fixed-size
                                    // avatar it sits on, not to the type scale.
                                    Image(systemName: "camera.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.controlLabel)
                                        .frame(width: 22, height: 22)
                                        .accessibilityHidden(true)
                                        .background(Theme.accent, in: Circle())
                                }
                                .overlay {
                                    if uploadingAvatar {
                                        Circle().fill(.black.opacity(0.35))
                                            .overlay(ProgressView().tint(.white))
                                    }
                                }
                        }
                        .accessibilityIdentifier("settings.avatar")
                        VStack(alignment: .leading, spacing: 4) {
                            // A text field cannot wrap, so its size is capped:
                            // .headline would truncate the name at large sizes.
                            TextField("Name", text: $displayName)
                                .textRole(Theme.Text.rowTitle)
                                .accessibilityIdentifier("settings.displayName")
                            Text("@\(app.session?.username ?? "")")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    TextField("Bio", text: $bio, axis: .vertical)
                        .lineLimit(1...3)
                    NavigationLink {
                        UsernameView()
                    } label: {
                        HStack {
                            Text("Username")
                            Spacer()
                            Text("@\(app.session?.username ?? "")")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("settings.username")
                } footer: {
                    if let hint = nameError {
                        Text(hint).foregroundStyle(.red)
                    } else {
                        Text("Your name is what people see in the chat list and the conversation header.")
                    }
                }

                Section("Appearance") {
                    HStack(spacing: 12) {
                        ForEach(Palette.allCases) { palette in
                            PaletteCard(palette: palette, selected: theme.palette == palette) {
                                Haptics.light()
                                theme.palette = palette
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    // the language is the system's per-app setting: the bundle
                    // carries two localizations, so Settings shows the row and
                    // relaunches the app in the chosen one
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        HStack {
                            Label("Language", systemImage: "globe")
                            Spacer()
                            Text(Self.currentLanguageName)
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.up.forward.app")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("settings.language")
                }

                Section("Notifications") {
                    Toggle(isOn: $showsMessageText) {
                        Label("Show message text", systemImage: "text.bubble")
                    }
                    .onChange(of: showsMessageText) { _, on in
                        NotificationPreferences.setShowsMessageText(on, in: AppGroup.defaults)
                    }
                    Text(showsMessageText
                         ? "The banner shows the sender's name and the text."
                         : "The banner keeps the sender's name and avatar; the text is hidden.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Security") {
                    Toggle(isOn: $pinEnabled) {
                        Label("Passcode", systemImage: "lock")
                    }
                    .onChange(of: pinEnabled) { _, on in
                        if on { showPinSetup = true } else { PinStore.removePin() }
                    }
                    if pinEnabled {
                        Toggle(isOn: $biometrics) {
                            Label("Face ID", systemImage: "faceid")
                        }
                        .onChange(of: biometrics) { _, on in
                            PinStore.setBiometricsEnabled(on)
                        }
                    }
                    NavigationLink {
                        BlockedListView()
                    } label: {
                        Label("Blocked users", systemImage: "hand.raised")
                    }
                    NavigationLink {
                        SessionsView()
                    } label: {
                        Label("Active devices", systemImage: "laptopcomputer.and.iphone")
                    }
                }

                Section("Data") {
                    Button {
                        app.media?.clearCache()
                        cacheSize = app.media?.totalCacheSize() ?? 0
                    } label: {
                        HStack {
                            Label("Clear media cache", systemImage: "trash")
                            Spacer()
                            Text(Self.sizeLabel(cacheSize))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onAppear { cacheSize = app.media?.totalCacheSize() ?? 0 }
                }

                Section {
                    Button(role: .destructive) {
                        showLogoutConfirm = true
                    } label: {
                        Label("Log out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .accessibilityIdentifier("settings.logout")
                } footer: {
                    Text("This device's access to the account is revoked; messages and keys are deleted.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { Task { await saveProfile() } }
                        .accessibilityIdentifier("settings.done")
                }
            }
            .task { await loadMe() }
            .onChange(of: displayName) { _, _ in nameError = nil }
            .onChange(of: avatarItem) { _, item in
                guard let item else { return }
                Task { await uploadAvatar(item) }
            }
            .confirmationDialog("Log out of the account?", isPresented: $showLogoutConfirm,
                                titleVisibility: .visible) {
                Button("Log out", role: .destructive) {
                    dismiss()
                    Task { await app.logout() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Messages and keys on this device will be deleted. They cannot be recovered.")
            }
            .sheet(isPresented: $showPinSetup) {
                PinSetupView { pin in
                    PinStore.setPin(pin)
                    showPinSetup = false
                } onCancel: {
                    pinEnabled = false
                    showPinSetup = false
                }
            }
        }
    }

    private func loadMe() async {
        me = try? await app.db.read { [id = app.session?.userId ?? ""] dbc in
            try User.fetchOne(dbc, key: id)
        }
        displayName = me?.displayName ?? ""
        bio = me?.bio ?? ""
    }

    /// A name has to be there: it is what a peer reads instead of a handle.
    /// An emptied field keeps the screen open with the reason under it.
    private func saveProfile() async {
        guard AccountValidator.isValidName(displayName) else {
            nameError = AccountValidator.nameHint(displayName) ?? String(localized: "Name cannot be empty")
            return
        }
        let name = AccountValidator.trimmedName(displayName)
        try? await app.api.updateProfile(displayName: name, bio: bio)
        // the row the screens read is ours to keep in step: the frame the
        // server sends out over this change goes to everyone but us
        if let id = app.session?.userId {
            try? await app.db.write { dbc in
                try dbc.execute(sql: "UPDATE user SET displayName = ?, bio = ? WHERE id = ?",
                                arguments: [name, bio, id])
            }
        }
        dismiss()
    }

    private func uploadAvatar(_ item: PhotosPickerItem) async {
        uploadingAvatar = true
        defer { uploadingAvatar = false }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let prepared = ImageProcessor.prepareForSending(data, maxDimension: 640),
              let avatarId = try? await app.api.uploadAvatar(prepared.data) else { return }
        if let id = app.session?.userId {
            try? await app.db.write { dbc in
                try dbc.execute(sql: "UPDATE user SET avatarId = ? WHERE id = ?",
                                arguments: [avatarId, id])
            }
        }
        await loadMe()
    }

    /// Cache size by hand: ByteCountFormatter writes "Zero KB" under the system locale.
    /// The language the interface is running in, named in that language
    /// («Русский», "English"), as the row's value.
    static var currentLanguageName: String {
        let locale = Locale.current
        guard let code = locale.language.languageCode?.identifier,
              let name = locale.localizedString(forLanguageCode: code) else { return "" }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    static func sizeLabel(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024
        switch kb {
        case ..<1: return String(localized: "0 KB")
        case ..<1024: return String(localized: "\(Int(kb.rounded())) KB")
        case ..<(1024 * 1024): return String(localized: "\(kb / 1024, specifier: "%.1f") MB")
        default: return String(localized: "\(kb / 1024 / 1024, specifier: "%.2f") GB")
        }
    }
}

/// A palette preset card: a miniature chat mock-up (background, incoming and
/// outgoing bubbles, accent button) with the preset's name. The current preset
/// is outlined in the accent colour and carries a checkmark.
struct PaletteCard: View {
    let palette: Palette
    let selected: Bool
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(palette.chatBackground)
                    VStack(alignment: .leading, spacing: 5) {
                        Capsule()
                            .fill(palette.incomingBubble)
                            .frame(width: 44, height: 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Capsule()
                            .fill(palette.outgoingBubble)
                            .frame(width: 52, height: 14)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        HStack {
                            Capsule()
                                .fill(palette.incomingBubble)
                                .frame(width: 32, height: 14)
                            Spacer()
                            Circle()
                                .fill(palette.accent)
                                .frame(width: 14, height: 14)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 76)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? palette.accent : Color(.separator),
                                      lineWidth: selected ? 2 : 0.5)
                }
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(Theme.glyph(16, max: 24))
                            .foregroundStyle(.white, palette.accent)
                            .padding(4)
                    }
                }
                Text(palette.title)
                    .font(.caption)
                    .fontWeight(selected ? .semibold : .regular)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

struct PinSetupView: View {
    var onSet: (String) -> Void
    var onCancel: () -> Void
    @State private var first = ""
    @State private var entered = ""
    @State private var stage = 0 // 0 = entry, 1 = confirmation

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Text(stage == 0 ? "Choose a passcode" : "Repeat the passcode")
                .font(.headline)
            HStack(spacing: 18) {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .strokeBorder(.secondary, lineWidth: 1.2)
                        .background(Circle().fill(i < entered.count ? Color.primary : .clear))
                        .frame(width: 14, height: 14)
                }
            }
            PinPad { key in
                switch key {
                case .digit(let d):
                    guard entered.count < 4 else { return }
                    entered.append(d)
                    if entered.count == 4 {
                        if stage == 0 {
                            first = entered
                            entered = ""
                            stage = 1
                        } else if entered == first {
                            onSet(entered)
                        } else {
                            Haptics.rigid()
                            entered = ""
                            stage = 0
                        }
                    }
                case .delete:
                    if !entered.isEmpty { entered.removeLast() }
                case .biometrics:
                    break
                }
            }
            Button("Cancel", action: onCancel)
            Spacer()
        }
    }
}

struct BlockedListView: View {
    @EnvironmentObject var app: AppState
    @State private var blocked: [User] = []

    var body: some View {
        List(blocked) { user in
            HStack {
                AvatarView(name: user.displayName, avatarId: user.avatarId)
                    .frame(width: 36, height: 36)
                Text(user.displayName)
                Spacer()
                Button("Unblock") {
                    Task {
                        try? await app.engine.setBlocked(userId: user.id, blocked: false)
                        blocked.removeAll { $0.id == user.id }
                    }
                }
                .font(.footnote)
            }
        }
        .navigationTitle("Blocked users")
        .task {
            guard let ids = try? await app.api.blockedUsers() else { return }
            blocked = (try? await app.db.read { dbc in
                try ids.compactMap { try User.fetchOne(dbc, key: $0) }
            }) ?? []
        }
    }
}
