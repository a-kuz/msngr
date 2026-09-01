import SwiftUI
import MsngrCore

/// The folder list: tab order, renaming, deleting, creating. Folders live on
/// this device, and the footer says so, so nobody waits for the tabs they laid
/// out here to turn up on another phone.
struct ChatFoldersView: View {
    @ObservedObject var model: ChatListModel
    @Environment(\.dismiss) private var dismiss
    /// `EditButton()` reads the real system locale and not the app's own, so on
    /// a device where they disagree it lands in a different language than every
    /// other string on this screen. A button of our own, on the same catalog as
    /// the rest of the toolbar, can't drift out of step with it.
    @Environment(\.editMode) private var editMode
    /// The folder open in the editor; a target holding no folder creates a new one.
    @State private var editing: EditorTarget?

    private var isEditing: Bool { editMode?.wrappedValue.isEditing ?? false }

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
                        Text("A folder collects chats by a rule — people, groups, unread — and keeps whatever you add by hand.")
                    } else {
                        Text("Folder order is tab order. Deleting a folder removes only it — the chats stay put. Folders live on this device.")
                    }
                }

                Section {
                    Button { editing = EditorTarget(folder: nil) } label: {
                        Label("New Folder", systemImage: "plus")
                    }
                    .accessibilityIdentifier("folders.new")
                }
            }
            .navigationTitle("Folders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !model.folders.isEmpty {
                        Button(isEditing ? "Done" : "Edit") {
                            editMode?.wrappedValue = isEditing ? .inactive : .active
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editing) { target in
                ChatFolderEditorView(model: model, folder: target.folder)
            }
        }
    }

    private func subtitle(_ folder: ChatFolder) -> String {
        var parts: [String] = []
        if folder.rules.direct { parts.append(String(localized: "People")) }
        if folder.rules.groups { parts.append(String(localized: "Groups")) }
        if folder.rules.unread { parts.append(String(localized: "Unread")) }
        if !folder.rules.peerIds.isEmpty {
            parts.append(String(localized: "Contacts: \(folder.rules.peerIds.count)"))
        }
        let count = model.chatIds(in: folder).count
        parts.append(count == 1 ? String(localized: "1 chat") : String(localized: "\(count) chats"))
        return parts.joined(separator: " · ")
    }
}

/// A single folder: name, rules and contents. It all goes in one save.
struct ChatFolderEditorView: View {
    @ObservedObject var model: ChatListModel
    let folder: ChatFolder?
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var direct = false
    @State private var groups = false
    @State private var unread = false
    @State private var peerIds: Set<String> = []
    /// Where the contents diverge from the rule: added by hand, removed by hand.
    /// The rule is evaluated live, so its checkmarks move with the toggles while
    /// the user's own decisions outlive them.
    @State private var handAdded: Set<String> = []
    @State private var handRemoved: Set<String> = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $title)
                        .accessibilityIdentifier("folder.title")
                }

                Section("What's included automatically") {
                    Toggle("People", isOn: $direct)
                        .accessibilityIdentifier("folder.rule.direct")
                    Toggle("Groups", isOn: $groups)
                        .accessibilityIdentifier("folder.rule.groups")
                    Toggle("Unread", isOn: $unread)
                        .accessibilityIdentifier("folder.rule.unread")
                }

                if !contacts.isEmpty {
                    Section("Chats with contacts") {
                        ForEach(contacts, id: \.id) { peer in
                            pickerRow(title: peer.displayName, selected: peerIds.contains(peer.id)) {
                                if peerIds.contains(peer.id) { peerIds.remove(peer.id) }
                                else { peerIds.insert(peer.id) }
                            }
                        }
                    }
                }

                Section("Chats") {
                    ForEach(model.items) { item in
                        pickerRow(title: item.title, selected: chatIds.contains(item.id)) {
                            toggleChat(item.id)
                        }
                    }
                }
            }
            .navigationTitle(folder == nil ? "New Folder" : "Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
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

    /// What the rule brings in right now, with the toggles as they stand on screen.
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
