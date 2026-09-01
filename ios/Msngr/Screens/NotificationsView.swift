import SwiftUI
import MsngrCore
import GRDB

/// Notifications: the banner preview toggle, the default sounds by chat
/// shape, and the list of every chat and person that overrides them.
struct NotificationsView: View {
    @EnvironmentObject var app: AppState
    @State private var showsMessageText = NotificationPreferences.showsMessageText(in: AppGroup.defaults)
    @State private var directSound: NotifySound = .standard
    @State private var groupSound: NotifySound = .standard
    @State private var soundsLoaded = false
    @State private var chatRows: [ExceptionRow] = []
    @State private var personRows: [ExceptionRow] = []

    struct ExceptionRow: Identifiable, Equatable {
        let id: String        // chatId or userId
        let title: String
        let sound: String
    }

    var body: some View {
        List {
            Section {
                Toggle(isOn: $showsMessageText) {
                    Label("Show message text", systemImage: "text.bubble")
                }
                .onChange(of: showsMessageText) { _, on in
                    NotificationPreferences.setShowsMessageText(on, in: AppGroup.defaults)
                }
            } footer: {
                Text(showsMessageText
                     ? "The banner shows the sender's name and the text."
                     : "The banner keeps the sender's name and avatar; the text is hidden.")
            }

            Section("Default sounds") {
                Picker(selection: $directSound) {
                    ForEach(NotifySound.allCases) { option in
                        Text(option.label).tag(option)
                    }
                } label: {
                    Label("Sound: direct chats", systemImage: "bell")
                }
                .accessibilityIdentifier("settings.sound.direct")
                .onChange(of: directSound) { _, new in
                    guard soundsLoaded else { return }
                    new.preview()
                    Task { try? await app.api.setNotifySounds(direct: new.rawValue) }
                }
                Picker(selection: $groupSound) {
                    ForEach(NotifySound.allCases) { option in
                        Text(option.label).tag(option)
                    }
                } label: {
                    Label("Sound: groups", systemImage: "bell.and.waves.left.and.right")
                }
                .accessibilityIdentifier("settings.sound.group")
                .onChange(of: groupSound) { _, new in
                    guard soundsLoaded else { return }
                    new.preview()
                    Task { try? await app.api.setNotifySounds(group: new.rawValue) }
                }
            }

            if !chatRows.isEmpty {
                Section {
                    ForEach(chatRows) { row in
                        exceptionRow(row)
                            .swipeActions {
                                Button(role: .destructive) {
                                    Task {
                                        try? await app.api.setChatFlags(row.id, sound: "default")
                                        chatRows.removeAll { $0.id == row.id }
                                    }
                                } label: { Label("Remove", systemImage: "trash") }
                            }
                    }
                } header: {
                    Text("Chats with their own sound")
                }
            }

            if !personRows.isEmpty {
                Section {
                    ForEach(personRows) { row in
                        exceptionRow(row)
                            .swipeActions {
                                Button(role: .destructive) {
                                    Task {
                                        try? await app.api.setPersonSound(row.id, sound: "default")
                                        personRows.removeAll { $0.id == row.id }
                                    }
                                } label: { Label("Remove", systemImage: "trash") }
                            }
                    }
                } header: {
                    Text("People with their own sound")
                } footer: {
                    Text("A person's sound plays wherever they write; a chat's own sound still wins inside that chat.")
                }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func exceptionRow(_ row: ExceptionRow) -> some View {
        HStack {
            Text(row.title)
            Spacer()
            Text(NotifySound(rawValue: row.sound)?.label ?? row.sound)
                .foregroundStyle(.secondary)
        }
    }

    private func load() async {
        if let sounds = try? await app.api.notifySounds() {
            directSound = NotifySound(rawValue: sounds.direct ?? "") ?? .standard
            groupSound = NotifySound(rawValue: sounds.group ?? "") ?? .standard
        }
        soundsLoaded = true
        guard let dto = try? await app.api.soundExceptions(), let db = app.db else { return }
        let ownId = app.session?.userId ?? ""
        let resolved: ([ExceptionRow], [ExceptionRow])? = try? await db.read { dbc in
            var chats: [ExceptionRow] = []
            for entry in dto.chats {
                guard let chat = try Chat.fetchOne(dbc, key: entry.chatId) else { continue }
                let title: String
                switch chat.kind {
                case .group:
                    title = chat.title ?? String(localized: "Group")
                case .saved:
                    title = String(localized: "Saved Messages")
                case .direct:
                    title = try String.fetchOne(dbc, sql: """
                        SELECT u.displayName FROM member m JOIN user u ON u.id = m.userId
                        WHERE m.chatId = ? AND m.userId != ?
                        """, arguments: [entry.chatId, ownId]) ?? chat.title ?? entry.chatId
                }
                chats.append(ExceptionRow(id: entry.chatId, title: title, sound: entry.sound))
            }
            var people: [ExceptionRow] = []
            for entry in dto.people {
                let name = try User.fetchOne(dbc, key: entry.userId)?.displayName ?? entry.userId
                people.append(ExceptionRow(id: entry.userId, title: name, sound: entry.sound))
            }
            return (chats.sorted { $0.title < $1.title }, people.sorted { $0.title < $1.title })
        }
        if let (chats, people) = resolved {
            chatRows = chats
            personRows = people
        }
    }
}
