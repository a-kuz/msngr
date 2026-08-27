import SwiftUI
import Contacts
import CryptoKit
import MsngrCore

/// A new chat: search by username, contacts from the address book, group creation.
struct NewChatView: View {
    var onOpen: (String) -> Void
    @EnvironmentObject var app: AppState
    @ObservedObject private var theme = ThemeStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [APIClient.UserDTO] = []
    @State private var contacts: [ContactMatch] = []
    @State private var contactsDenied = false
    @State private var contactsStatus = CNContactStore.authorizationStatus(for: .contacts)
    @State private var groupMode = false
    @State private var groupTitle = ""
    @State private var selected: Set<String> = []
    /// The search in flight. A keystroke cancels it: without that every letter
    /// left its own request running, the answers came back in whatever order
    /// and an older one could overwrite the results of the newest query.
    @State private var searchTask: Task<Void, Never>?
    /// The query the results on screen answer. "No results" is said about
    /// this one only — while a newer query is still on its way the screen has
    /// nothing to report yet.
    @State private var answered = ""

    struct ContactMatch: Identifiable {
        let id: String       // userId
        let username: String
        let bookName: String // the address book name takes precedence
        let avatarId: String?
    }

    var body: some View {
        NavigationStack {
            List {
                if groupMode {
                    Section {
                        TextField("Group name", text: $groupTitle)
                    }
                }
                if !results.isEmpty {
                    Section("Global search") {
                        ForEach(results, id: \.id) { u in
                            row(id: u.id, name: u.display_name, username: u.username, avatarId: u.avatar_id)
                        }
                    }
                }
                if !contacts.isEmpty {
                    Section("Contacts") {
                        ForEach(contacts) { c in
                            row(id: c.id, name: c.bookName, username: c.username, avatarId: c.avatarId)
                        }
                    }
                }
                if contactsDenied {
                    Section {
                        Text("Allow contact access in Settings to find people you know")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if !groupMode && results.isEmpty && contacts.isEmpty {
                    if query.count >= 2, answered != query {
                        ProgressView()
                    } else if query.count >= 2 {
                        ContentUnavailableView.search(text: query)
                    } else {
                        ContentUnavailableView {
                            Label("Find someone", systemImage: "person.crop.circle.badge.plus")
                        } description: {
                            Text("Enter a username or a name.")
                        } actions: {
                            if contactsStatus == .notDetermined {
                                Button {
                                    Task { await requestContactsAndSync() }
                                } label: {
                                    Label("Find via contacts", systemImage: "person.2")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Username or name")
            // the field searches usernames: autocapitalisation and autocorrection get in the way
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onChange(of: query) { _, q in
                searchTask?.cancel()
                guard q.count >= 2 else {
                    results = []
                    answered = q
                    return
                }
                searchTask = Task {
                    // typing is faster than a round trip: the request goes out
                    // once the letters stop, not once per letter
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                    let found = (try? await app.api.searchUsers(q)) ?? []
                    guard !Task.isCancelled else { return }
                    results = found
                    answered = q
                }
            }
            .navigationTitle(groupMode ? "New group" : "New chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if groupMode {
                        Button("Create") {
                            Task { await createGroup() }
                        }
                        .disabled(selected.isEmpty || groupTitle.isEmpty)
                    } else {
                        Button {
                            withAnimation { groupMode = true }
                        } label: {
                            Image(systemName: "person.3")
                        }
                    }
                }
            }
            // the system contacts permission dialog comes up only on an explicit
            // tap of the "find via contacts" button; with access already granted the sync
            // starts straight away
            .task {
                if contactsStatus == .authorized { await syncContacts() }
            }
        }
    }

    @ViewBuilder
    private func row(id: String, name: String, username: String, avatarId: String?) -> some View {
        Button {
            if groupMode {
                if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            } else {
                Task { await openDirect(id) }
            }
        } label: {
            HStack {
                AvatarView(name: name, avatarId: avatarId)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading) {
                    Text(name).foregroundStyle(.primary)
                    Text("@\(username)").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if groupMode {
                    Image(systemName: selected.contains(id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected.contains(id) ? Theme.accent : .secondary)
                }
            }
            // the row answers across its whole width, not only on the letters
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openDirect(_ userId: String) async {
        guard let chatId = await DirectChat.open(userId: userId) else { return }
        onOpen(chatId)
    }

    private func createGroup() async {
        guard let chatId = try? await app.api.createChat(kind: "group",
                                                         memberIds: Array(selected),
                                                         title: groupTitle) else { return }
        try? await app.engine.refreshSnapshot()
        onOpen(chatId)
    }

    /// Asks for contacts access on an explicit user action, then syncs.
    private func requestContactsAndSync() async {
        _ = try? await CNContactStore().requestAccess(for: .contacts)
        contactsStatus = CNContactStore.authorizationStatus(for: .contacts)
        if contactsStatus == .authorized {
            await syncContacts()
        } else {
            contactsDenied = true
        }
    }

    /// Address book sync: E.164 → SHA-256 → discovery. Access must already be granted.
    private func syncContacts() async {
        let store = CNContactStore()
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            contactsDenied = true
            return
        }
        let keys = [CNContactPhoneNumbersKey, CNContactGivenNameKey, CNContactFamilyNameKey] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var hashToName: [String: String] = [:]
        try? store.enumerateContacts(with: request) { contact, _ in
            let name = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
            for phone in contact.phoneNumbers {
                let normalized = Self.e164(phone.value.stringValue)
                guard !normalized.isEmpty else { continue }
                let hash = SHA256.hash(data: Data(normalized.utf8))
                    .map { String(format: "%02x", $0) }.joined()
                hashToName[hash] = name.isEmpty ? normalized : name
            }
        }
        guard !hashToName.isEmpty,
              let matches = try? await app.api.discoverContacts(hashes: Array(hashToName.keys)) else { return }
        contacts = matches.map {
            ContactMatch(id: $0.id, username: $0.username,
                         bookName: hashToName[$0.phone_hash] ?? $0.display_name,
                         avatarId: $0.avatar_id)
        }
        .sorted { $0.bookName < $1.bookName }
    }

    static func e164(_ raw: String) -> String {
        var digits = raw.filter { $0.isNumber || $0 == "+" }
        if digits.hasPrefix("8") && digits.count == 11 {
            digits = "+7" + digits.dropFirst() // Russian format
        }
        guard digits.hasPrefix("+"), digits.count >= 11 else { return "" }
        return digits
    }
}

/// Picking the chat to forward into.
struct ForwardPickerView: View {
    var onPick: (String) -> Void
    @StateObject private var model = ChatListModel()
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(model.items + model.archived) { item in
                Button {
                    onPick(item.chat.id)
                    dismiss()
                } label: {
                    HStack {
                        AvatarView(name: item.title, avatarId: item.avatarId, glyph: item.avatarGlyph)
                            .frame(width: 40, height: 40)
                        Text(item.title).foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Forward to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { model.start() }
        }
    }
}
