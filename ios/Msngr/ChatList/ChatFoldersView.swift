import SwiftUI
import MsngrCore

/// Список папок: порядок вкладок, переименование, удаление, создание.
/// Папки живут на этом устройстве — про это сказано строкой внизу, чтобы
/// разложенные вкладки не ждали на другом телефоне.
struct ChatFoldersView: View {
    @ObservedObject var model: ChatListModel
    @Environment(\.dismiss) private var dismiss
    /// Папка, открытая в редакторе; nil в `editing` при создании новой.
    @State private var editing: EditorTarget?

    private struct EditorTarget: Identifiable {
        var folder: ChatFolder?
        var id: String { folder?.id ?? "new" }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.folders) { folder in
                        Button { editing = EditorTarget(folder: folder) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(folder.title).foregroundStyle(.primary)
                                    Text(subtitle(folder))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .onMove { source, destination in
                        var ordered = model.folders
                        ordered.move(fromOffsets: source, toOffset: destination)
                        model.reorderFolders(ordered)
                    }
                    .onDelete { offsets in
                        for index in offsets { model.deleteFolder(model.folders[index]) }
                    }
                } footer: {
                    if model.folders.isEmpty {
                        Text("Папка собирает чаты по правилу — люди, группы, непрочитанные — и держит те, что вы добавите руками.")
                    } else {
                        Text("Порядок папок — порядок вкладок. Удаление папки убирает только её: чаты остаются на месте. Папки хранятся на этом устройстве.")
                    }
                }

                Section {
                    Button { editing = EditorTarget(folder: nil) } label: {
                        Label("Новая папка", systemImage: "plus")
                    }
                    .accessibilityIdentifier("folders.new")
                }
            }
            .navigationTitle("Папки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
            .sheet(item: $editing) { target in
                ChatFolderEditorView(model: model, folder: target.folder)
            }
        }
    }

    private func subtitle(_ folder: ChatFolder) -> String {
        var parts: [String] = []
        if folder.rules.direct { parts.append("Люди") }
        if folder.rules.groups { parts.append("Группы") }
        if folder.rules.unread { parts.append("Непрочитанные") }
        if !folder.rules.peerIds.isEmpty { parts.append("Контакты: \(folder.rules.peerIds.count)") }
        let count = model.chatIds(in: folder).count
        parts.append(count == 1 ? "1 чат" : "\(count) чатов")
        return parts.joined(separator: " · ")
    }
}

/// Одна папка: имя, правила и её состав. Всё уходит одним сохранением.
struct ChatFolderEditorView: View {
    @ObservedObject var model: ChatListModel
    let folder: ChatFolder?
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var direct = false
    @State private var groups = false
    @State private var unread = false
    @State private var peerIds: Set<String> = []
    /// Расхождения с правилом: что добавлено руками и что руками убрано.
    /// Правило считается на лету, поэтому его галочки переезжают вслед за
    /// переключателем, а решения пользователя переживают его.
    @State private var handAdded: Set<String> = []
    @State private var handRemoved: Set<String> = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Название", text: $title)
                        .accessibilityIdentifier("folder.title")
                }

                Section("Что попадает само") {
                    Toggle("Люди", isOn: $direct)
                        .accessibilityIdentifier("folder.rule.direct")
                    Toggle("Группы", isOn: $groups)
                        .accessibilityIdentifier("folder.rule.groups")
                    Toggle("Непрочитанные", isOn: $unread)
                        .accessibilityIdentifier("folder.rule.unread")
                }

                if !contacts.isEmpty {
                    Section("Чаты с контактами") {
                        ForEach(contacts, id: \.id) { peer in
                            pickerRow(title: peer.displayName, selected: peerIds.contains(peer.id)) {
                                if peerIds.contains(peer.id) { peerIds.remove(peer.id) }
                                else { peerIds.insert(peer.id) }
                            }
                        }
                    }
                }

                Section("Чаты") {
                    ForEach(model.items) { item in
                        pickerRow(title: item.title, selected: chatIds.contains(item.id)) {
                            toggleChat(item.id)
                        }
                    }
                }
            }
            .navigationTitle(folder == nil ? "Новая папка" : "Папка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Сохранить") { save() }
                        .fontWeight(.semibold)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("folder.save")
                }
            }
            .onAppear(perform: load)
        }
    }

    private var contacts: [User] {
        var seen: Set<String> = []
        return model.items.compactMap(\.peer).filter { seen.insert($0.id).inserted }
    }

    private var rules: ChatFolderRules {
        ChatFolderRules(direct: direct, groups: groups, unread: unread, peerIds: peerIds)
    }

    private func pickerRow(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Theme.accent : Color.secondary)
            }
        }
    }

    /// Что даёт правило прямо сейчас, с учётом переключателей на экране.
    private var broughtByRules: Set<String> { brought(by: rules) }

    private func brought(by rules: ChatFolderRules) -> Set<String> {
        Set(model.items.filter { item in
            ChatFolderMembership.matches(
                ChatFolderCandidate(chatId: item.id,
                                    isGroup: item.chat.kind == .group,
                                    hasUnread: item.chat.unreadCount > 0,
                                    peerId: item.peer?.id),
                rules: rules, pin: nil)
        }.map(\.id))
    }

    private var chatIds: Set<String> {
        broughtByRules.union(handAdded).subtracting(handRemoved)
    }

    private func toggleChat(_ id: String) {
        let byRule = broughtByRules.contains(id)
        if chatIds.contains(id) {
            handAdded.remove(id)
            if byRule { handRemoved.insert(id) }
        } else {
            handRemoved.remove(id)
            if !byRule { handAdded.insert(id) }
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let folder else { return }
        title = folder.title
        direct = folder.rules.direct
        groups = folder.rules.groups
        unread = folder.rules.unread
        peerIds = folder.rules.peerIds
        let current = model.chatIds(in: folder)
        let byRule = brought(by: folder.rules)
        handAdded = current.subtracting(byRule)
        handRemoved = byRule.subtracting(current)
    }

    private func save() {
        model.saveFolder(folder, title: title.trimmingCharacters(in: .whitespaces),
                         rules: rules, chatIds: chatIds)
        dismiss()
    }
}
