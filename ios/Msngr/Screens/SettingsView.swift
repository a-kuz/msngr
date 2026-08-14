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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        PhotosPicker(selection: $avatarItem, matching: .images) {
                            AvatarView(name: me?.displayName ?? "", avatarId: me?.avatarId)
                                .frame(width: 66, height: 66)
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: "camera.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white)
                                        .frame(width: 22, height: 22)
                                        .background(Theme.accent, in: Circle())
                                }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Имя", text: $displayName)
                                .font(.headline)
                            Text("@\(app.session?.username ?? "")")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    TextField("О себе", text: $bio, axis: .vertical)
                        .lineLimit(1...3)
                }

                Section("Оформление") {
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

                Section("Безопасность") {
                    Toggle(isOn: $pinEnabled) {
                        Label("Код-пароль", systemImage: "lock")
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
                        Label("Заблокированные", systemImage: "hand.raised")
                    }
                }

                Section("Данные") {
                    Button {
                        app.media?.clearCache()
                    } label: {
                        HStack {
                            Label("Очистить кэш медиа", systemImage: "trash")
                            Spacer()
                            Text(Self.sizeLabel(app.media?.totalCacheSize() ?? 0))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") {
                        Task {
                            try? await app.api.updateProfile(
                                displayName: displayName.isEmpty ? nil : displayName,
                                bio: bio.isEmpty ? nil : bio)
                            dismiss()
                        }
                    }
                }
            }
            .task {
                me = try? await app.db.read { [id = app.session?.userId ?? ""] dbc in
                    try User.fetchOne(dbc, key: id)
                }
                displayName = me?.displayName ?? ""
                bio = me?.bio ?? ""
            }
            .onChange(of: avatarItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let prepared = ImageProcessor.prepareForSending(data, maxDimension: 640) {
                        _ = try? await app.api.uploadAvatar(prepared.data)
                    }
                }
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

    /// Размер кэша по-русски: ByteCountFormatter пишет «Zero KB» на системной локали.
    static func sizeLabel(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024
        switch kb {
        case ..<1: return "0 КБ"
        case ..<1024: return String(format: "%.0f КБ", kb)
        case ..<(1024 * 1024): return String(format: "%.1f МБ", kb / 1024)
        default: return String(format: "%.2f ГБ", kb / 1024 / 1024)
        }
    }
}

/// Карточка пресета палитры: мини-мокап чата (фон, входящий и исходящий бабблы,
/// акцентная кнопка) + название; текущий пресет обведён акцентом с галочкой.
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
                            .font(.system(size: 16))
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
    @State private var stage = 0 // 0 = ввод, 1 = повтор

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Text(stage == 0 ? "Придумайте код-пароль" : "Повторите код-пароль")
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
            Button("Отмена", action: onCancel)
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
                Button("Разблокировать") {
                    Task {
                        try? await app.api.setBlocked(user.id, blocked: false)
                        blocked.removeAll { $0.id == user.id }
                    }
                }
                .font(.footnote)
            }
        }
        .navigationTitle("Заблокированные")
        .task {
            guard let ids = try? await app.api.blockedUsers() else { return }
            blocked = (try? await app.db.read { dbc in
                try ids.compactMap { try User.fetchOne(dbc, key: $0) }
            }) ?? []
        }
    }
}
