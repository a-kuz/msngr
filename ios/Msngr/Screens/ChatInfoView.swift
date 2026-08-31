import SwiftUI
import PhotosUI
import Combine
import GRDB
import MsngrCore
import MsngrCrypto

/// Roles of the chat members: the chat frame rewrites the member table, and
/// the observation keeps the screen current (admin taken away, controls gone).
@MainActor
final class ChatRolesModel: ObservableObject {
    @Published var roles: [String: String] = [:]
    private var cancellable: AnyCancellable?

    func start(chatId: String, db: DatabaseQueue?) {
        guard cancellable == nil, let db else { return }
        cancellable = ValueObservation
            .tracking { dbc in
                try Row.fetchAll(dbc, sql: "SELECT userId, role FROM member WHERE chatId = ?",
                                 arguments: [chatId])
            }
            .publisher(in: db, scheduling: .async(onQueue: .main))
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] rows in
                self?.roles = Dictionary(uniqueKeysWithValues: rows.map {
                    ($0["userId"] as String, $0["role"] as String)
                })
            })
    }
}

/// Chat info: the peer's profile, or managing the group.
struct ChatInfoView: View {
    @ObservedObject var model: ChatViewModel
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var rolesModel = ChatRolesModel()
    @State private var showAddMembers = false
    @State private var inviteLink: String?
    @State private var safetyNumber: String?
    @State private var editTitle = ""
    @State private var editDescription = ""
    @State private var ttl: Int = 0
    @State private var showMuteOptions = false
    @State private var showBlockConfirm = false
    @State private var showLeaveConfirm = false
    @State private var showClearConfirm = false
    @State private var avatarItem: PhotosPickerItem?
    @State private var savingSettings = false
    /// The attachments row's count: every gallery tab's entries, read once on
    /// appear rather than kept live.
    @State private var attachmentsCount: Int?
    #if DEBUG
    @State var seeding = false
    @State var seedSent = 0
    #endif

    private var isGroup: Bool { model.chat?.kind == .group }
    private var isSaved: Bool { model.chat?.kind == .saved }
    @ObservedObject private var surfaces = ShaderSurfaces.shared
    @State private var composingBackground = false
    @State private var composingShaderAvatar = false
    private var myRole: String? { rolesModel.roles[model.ownUserId] }
    private var kind: ChatKind { model.chat?.kind ?? .direct }
    /// Only an admin changes the group's name and avatar; the server checks the same.
    private var canEditSettings: Bool {
        ChatPermissions.canEditSettings(kind: kind, role: myRole)
    }
    private var canInvite: Bool {
        ChatPermissions.canInvite(kind: kind, role: myRole,
                                  invitePolicy: model.chat?.invitePolicy ?? ChatPermissions.openPolicy)
    }
    private var isMuted: Bool {
        MuteState.isMuted(muted: model.chat?.muted ?? false, mutedUntil: model.chat?.mutedUntil)
    }
    private var muteUntilLabel: String? {
        MuteState.untilLabel(muted: model.chat?.muted ?? false, mutedUntil: model.chat?.mutedUntil)
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    groupAvatar
                    if isGroup && canEditSettings {
                        TextField("Group name", text: $editTitle)
                            .font(.title3.bold())
                            .multilineTextAlignment(.center)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("chatInfo.title")
                            .onSubmit { saveTitle() }
                    } else {
                        Text(model.headerTitle).font(.title2.bold())
                    }
                    if !isSaved {
                        Text(isGroup ? ChatViewModel.membersText(model.members.count)
                             : "@\(model.peer?.username ?? "")")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if isGroup && canEditSettings && titleChanged {
                        Button("Save name", action: saveTitle)
                            .buttonStyle(.borderedProminent)
                            .disabled(savingSettings)
                            .accessibilityIdentifier("chatInfo.saveTitle")
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            if isGroup { descriptionSection }

            backgroundSection

            Section {
                NavigationLink {
                    ChatGalleryView(chatId: model.chatId)
                } label: {
                    HStack {
                        Label("Attachments", systemImage: "photo.on.rectangle.angled")
                        Spacer()
                        if let attachmentsCount {
                            Text(CountFormatter.short(attachmentsCount))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("chatInfo.gallery")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { isMuted },
                    set: { on in
                        if on {
                            showMuteOptions = true
                        } else {
                            applyMute(nil)
                        }
                    })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Mute", systemImage: "bell.slash")
                        if let muteUntilLabel {
                            Text(muteUntilLabel).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("chatInfo.mute")

                Picker(selection: $ttl) {
                    Text("Off").tag(0)
                    Text("24 hours").tag(86400)
                    Text("7 days").tag(604800)
                    Text("1 month").tag(2_592_000)
                    Text("90 days").tag(7_776_000)
                } label: {
                    Label("Auto-delete", systemImage: "timer")
                }
                .onChange(of: ttl) { _, newTTL in
                    guard newTTL != model.chat?.ttlSeconds else { return }
                    var c = ContentPayload(kind: "disappearing")
                    c.ttlSeconds = newTTL
                    model.enqueue(c)
                }
            }

            if !isGroup, let peer = model.peer {
                Section("Security") {
                    Button {
                        computeSafetyNumber(peer)
                    } label: {
                        Label("Safety number", systemImage: "checkmark.shield")
                    }
                    if let sn = safetyNumber {
                        Text(sn.chunked(5).joined(separator: "  "))
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Button(role: peer.isBlocked ? .none : .destructive) {
                        showBlockConfirm = true
                    } label: {
                        Label(peer.isBlocked ? "Unblock" : "Block",
                              systemImage: peer.isBlocked ? "hand.raised.slash" : "hand.raised")
                    }
                    .accessibilityIdentifier("chatInfo.block")
                }
            }

            if isGroup {
                if canEditSettings { rightsSection }
                Section {
                    ForEach(model.members) { member in
                        memberRow(member)
                    }
                    if canInvite {
                        Button {
                            showAddMembers = true
                        } label: {
                            Label("Add member", systemImage: "person.badge.plus")
                        }
                        .accessibilityIdentifier("chatInfo.addMember")
                        Button {
                            Task {
                                if let inv = try? await app.api.createInvite(model.chatId) {
                                    inviteLink = inv.link
                                    UIPasteboard.general.string = inv.link
                                }
                            }
                        } label: {
                            Label(inviteLink == nil ? "Invite link" : "Copied!",
                                  systemImage: "link")
                        }
                        .accessibilityIdentifier("chatInfo.invite")
                    }
                } header: {
                    HStack {
                        Text("Members")
                        Spacer()
                        Text(CountFormatter.short(model.members.count))
                    }
                }
            }
            destructiveSection
            #if DEBUG
            seedSection
            #endif
        }
        .navigationTitle(isGroup ? "Group" : isSaved ? "Saved Messages" : "Profile")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            ttl = model.chat?.ttlSeconds ?? 0
            editTitle = model.chat?.title ?? ""
            editDescription = model.chat?.chatDescription ?? ""
            rolesModel.start(chatId: model.chatId, db: app.db)
            loadAttachmentsCount()
        }
        .onChange(of: model.chat?.chatDescription) { _, new in
            if !descriptionChanged || editDescription.isEmpty { editDescription = new ?? "" }
        }
        // the title may have changed on another device while this screen was open
        .onChange(of: model.chat?.title) { _, new in
            if !titleChanged || editTitle.isEmpty { editTitle = new ?? "" }
        }
        .task { await app.engine?.refreshBlocked() }
        .sheet(isPresented: $showAddMembers) {
            AddMembersView(chatId: model.chatId, existing: Set(model.members.map(\.id))) { user in
                model.announce(.added, member: user.displayName, memberId: user.id)
            }
        }
        .confirmationDialog("Mute", isPresented: $showMuteOptions, titleVisibility: .visible) {
            ForEach(MuteOption.allCases, id: \.self) { option in
                Button(option.title) { applyMute(option) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(blockConfirmTitle, isPresented: $showBlockConfirm, titleVisibility: .visible) {
            let blocked = model.peer?.isBlocked ?? false
            Button(blocked ? "Unblock" : "Block",
                   role: blocked ? .none : .destructive) {
                toggleBlock()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.peer?.isBlocked ?? false
                 ? "They will be able to message you again."
                 : "They will not be able to message you, and their messages will not be delivered.")
        }
        .confirmationDialog(deleteConfirmTitle, isPresented: $showLeaveConfirm, titleVisibility: .visible) {
            Button(isGroup ? "Leave" : "Delete", role: .destructive) { deleteChat() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteConfirmMessage)
        }
        .confirmationDialog("Clear history?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { model.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(isGroup
                 ? "This chat's messages will be deleted from this device. The other members keep them."
                 : "This chat's messages will be deleted from this device. The other person keeps them.")
        }
        .onChange(of: avatarItem) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let prepared = ImageProcessor.prepareForSending(data, maxDimension: 640) else { return }
                guard (try? await app.api.uploadChatAvatar(chatId: model.chatId,
                                                           jpeg: prepared.data)) != nil else { return }
                if isGroup { model.announce(.avatar) }
            }
        }
    }

    /// The group's description. An admin edits it in place; everyone else reads
    /// it, and sees nothing at all while there is none.
    @ViewBuilder
    private var descriptionSection: some View {
        if canEditSettings {
            Section("Description") {
                TextField("What this group is about", text: $editDescription, axis: .vertical)
                    .lineLimit(1...5)
                    .accessibilityIdentifier("chatInfo.description")
                if descriptionChanged {
                    Button("Save description", action: saveDescription)
                        .disabled(savingSettings)
                        .accessibilityIdentifier("chatInfo.saveDescription")
                }
            }
        } else if let text = model.chat?.chatDescription, !text.isEmpty {
            Section("Description") {
                Text(text).accessibilityIdentifier("chatInfo.description")
            }
        }
    }

    /// Who may write and who may bring people in. The rows are an admin's to
    /// see: a member cannot change them and reads the outcome instead — the
    /// note in place of the input field, the missing invite button.
    private var rightsSection: some View {
        Section("Member rights") {
            Picker(selection: sendPolicyBinding) {
                Text("All members").tag(ChatPermissions.openPolicy)
                Text("Admins only").tag(ChatPermissions.adminPolicy)
            } label: {
                Label("Who can write", systemImage: "square.and.pencil")
            }
            .accessibilityIdentifier("chatInfo.sendPolicy")

            Picker(selection: invitePolicyBinding) {
                Text("All members").tag(ChatPermissions.openPolicy)
                Text("Admins only").tag(ChatPermissions.adminPolicy)
            } label: {
                Label("Who can invite", systemImage: "person.badge.plus")
            }
            .accessibilityIdentifier("chatInfo.invitePolicy")
        }
    }

    /// The rights the chat row holds; the picker follows the server's answer,
    /// which comes back as a chat frame.
    private var sendPolicyBinding: Binding<String> {
        Binding(get: { model.chat?.sendPolicy ?? ChatPermissions.openPolicy },
                set: { value in
                    guard value != model.chat?.sendPolicy else { return }
                    Task { try? await app.api.chatSettings(model.chatId, sendPolicy: value) }
                })
    }

    private var invitePolicyBinding: Binding<String> {
        Binding(get: { model.chat?.invitePolicy ?? ChatPermissions.openPolicy },
                set: { value in
                    guard value != model.chat?.invitePolicy else { return }
                    Task { try? await app.api.chatSettings(model.chatId, invitePolicy: value) }
                })
    }

    /// The chat's shader background: local to this device, set here or from
    /// a shader message's menu.
    private var backgroundSection: some View {
        Section("Background") {
            if let doc = surfaces.backgrounds[model.chatId] {
                HStack(spacing: 12) {
                    ShaderCanvasView(document: doc, running: true, deviceInputs: true, priority: .focus)
                        .frame(width: 44, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(doc.name ?? String(localized: "Shader"))
                    Spacer()
                    Button(String(localized: "Remove"), role: .destructive) {
                        surfaces.setBackground(nil, for: model.chatId)
                    }
                    .accessibilityIdentifier("chatInfo.background.remove")
                }
            }
            Button {
                composingBackground = true
            } label: {
                Label(surfaces.backgrounds[model.chatId] == nil ? "Shader background…" : "Change shader…",
                      systemImage: "sparkles")
            }
            .accessibilityIdentifier("chatInfo.background.set")
        }
        .sheet(isPresented: $composingBackground) {
            ShaderComposerScreen(purpose: .background, initial: surfaces.backgrounds[model.chatId]) { doc in
                surfaces.setBackground(doc, for: model.chatId)
            }
        }
    }

    /// Chat avatar: a photo picker for a group admin, a plain picture for everyone else.
    @ViewBuilder
    private var groupAvatar: some View {
        let avatar = AvatarView(name: model.headerTitle,
                                avatarId: isGroup ? model.chat?.avatarId : model.peer?.avatarId,
                                online: model.peer?.online ?? false,
                                glyph: model.avatarGlyph)
            .frame(width: 90, height: 90)
        if isGroup && canEditSettings {
            PhotosPicker(selection: $avatarItem, matching: .images) {
                avatar.overlay(alignment: .bottomTrailing) {
                    // Badge geometry belongs to the fixed-size avatar it sits
                    // on, not to the type scale.
                    Image(systemName: "camera.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .accessibilityHidden(true)
                        .background(Theme.accent, in: Circle())
                }
            }
            .accessibilityIdentifier("chatInfo.avatar")
            Button {
                composingShaderAvatar = true
            } label: {
                Label("Shader avatar…", systemImage: "sparkles").font(.footnote)
            }
            .accessibilityIdentifier("chatInfo.shaderAvatar")
            .sheet(isPresented: $composingShaderAvatar) {
                ShaderComposerScreen(purpose: .avatar) { doc in
                    Task {
                        guard (try? await app.api.uploadShaderAvatar(doc, chatId: model.chatId)) != nil else { return }
                        if isGroup { model.announce(.avatar) }
                    }
                }
            }
        } else {
            avatar
        }
    }

    @ViewBuilder
    private func memberRow(_ member: User) -> some View {
        let role = rolesModel.roles[member.id]
        HStack {
            AvatarView(name: member.displayName, avatarId: member.avatarId, online: member.online)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading) {
                Text(member.displayName)
                Text("@\(member.username)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if role == ChatPermissions.adminRole {
                Text("admin").font(.caption).foregroundStyle(.secondary)
            }
        }
        .swipeActions {
            if member.id != model.ownUserId,
               ChatPermissions.canRemoveMembers(kind: kind, role: myRole) {
                Button(role: .destructive) {
                    Task {
                        do {
                            try await app.api.updateMembers(model.chatId, add: [], remove: [member.id])
                            model.announce(.removed, member: member.displayName, memberId: member.id)
                        } catch {}
                    }
                } label: {
                    Label("Remove", systemImage: "person.badge.minus")
                }
            }
            if member.id != model.ownUserId,
               ChatPermissions.canManageAdmins(kind: kind, role: myRole) {
                let isAdmin = role == ChatPermissions.adminRole
                Button {
                    Task {
                        do {
                            try await app.api.setAdmin(model.chatId, userId: member.id, admin: !isAdmin)
                            model.announce(isAdmin ? .adminRevoked : .adminGranted,
                                           member: member.displayName, memberId: member.id)
                        } catch {}
                    }
                } label: {
                    Label(isAdmin ? "Revoke admin" : "Make admin",
                          systemImage: isAdmin ? "person.badge.minus" : "star")
                }
                .tint(.orange)
            }
        }
    }

    /// Clearing and deleting are both irreversible, so they stand apart and ask
    /// for confirmation in the same terms as blocking: what exactly goes away
    /// and what the other side keeps.
    @ViewBuilder
    private var destructiveSection: some View {
        Section {
            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Label("Clear history", systemImage: "eraser")
            }
            .accessibilityIdentifier("chatInfo.clearHistory")
            // the chat with yourself is cleared, never deleted: it is part of the account
            if (!isGroup && !isSaved) || ChatPermissions.canLeave(kind: kind, role: myRole) {
                Button(role: .destructive) {
                    showLeaveConfirm = true
                } label: {
                    Label(isGroup ? "Leave group" : "Delete chat",
                          systemImage: isGroup ? "rectangle.portrait.and.arrow.right" : "trash")
                }
                .accessibilityIdentifier(isGroup ? "chatInfo.leave" : "chatInfo.deleteChat")
            }
        }
    }

    private var deleteConfirmTitle: String {
        isGroup ? String(localized: "Leave group?") : String(localized: "Delete chat?")
    }

    private var deleteConfirmMessage: String {
        isGroup
            ? String(localized: "You will leave the group, and its messages will be deleted from this device.")
            : String(localized: "The chat and its messages will be deleted from this device. The other person keeps the conversation. If they write again, the chat comes back.")
    }

    private var titleChanged: Bool {
        editTitle != (model.chat?.title ?? "")
            && !editTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var descriptionChanged: Bool {
        editDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            != (model.chat?.chatDescription ?? "")
    }

    private var blockConfirmTitle: String {
        let name = model.peer?.displayName ?? ""
        return model.peer?.isBlocked ?? false
            ? String(localized: "Unblock \(name)")
            : String(localized: "Block \(name)")
    }

    /// The group hears about a change only once the server has taken it: an
    /// event about a title that was refused would be a line about nothing.
    private func saveTitle() {
        let title = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != model.chat?.title else { return }
        savingSettings = true
        Task {
            do {
                try await app.api.chatSettings(model.chatId, title: title)
                model.announce(.title, text: title)
            } catch {}
            savingSettings = false
        }
    }

    private func saveDescription() {
        let text = editDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != (model.chat?.chatDescription ?? "") else { return }
        savingSettings = true
        Task {
            do {
                try await app.api.chatSettings(model.chatId, description: text)
                model.announce(text.isEmpty ? .descriptionCleared : .description)
            } catch {}
            savingSettings = false
        }
    }

    /// nil unmutes; anything else mutes for the option's duration.
    private func applyMute(_ option: MuteOption?) {
        let until = option?.until()
        Task {
            try? await app.db.write { [id = model.chatId] dbc in
                try dbc.execute(sql: "UPDATE chat SET muted = ?, mutedUntil = ? WHERE id = ?",
                                arguments: [option != nil, until, id])
            }
            try? await app.api.setChatFlags(model.chatId, muted: option != nil, mutedUntil: until)
        }
    }

    private func toggleBlock() {
        guard let peer = model.peer else { return }
        let blocked = !peer.isBlocked
        Task { try? await app.engine.setBlocked(userId: peer.id, blocked: blocked) }
    }

    private func deleteChat() {
        model.deleteChat()
        dismiss()
    }

    private func loadAttachmentsCount() {
        guard let db = app.db else { return }
        let chatId = model.chatId
        Task {
            let counts = (try? await db.read { dbc in try ChatGallery.counts(dbc, chatId: chatId) }) ?? [:]
            attachmentsCount = counts.values.reduce(0, +)
        }
    }

    private func computeSafetyNumber(_ peer: User) {
        guard let theirSigningB64 = peer.identitySigning, let theirDHB64 = peer.identityDH else {
            // fetch the peer's keys from the prekey bundle
            Task {
                if let bundles = try? await app.api.prekeys(userId: peer.id).bundles, let b = bundles.first {
                    try? await app.db.write { dbc in
                        try dbc.execute(sql: "UPDATE user SET identitySigning = ?, identityDH = ? WHERE id = ?",
                                        arguments: [b.identitySignKey, b.identityKey, peer.id])
                    }
                    await MainActor.run {
                        computeSafetyNumberNow(peer, theirSigning: b.identitySignKey,
                                               theirDH: b.identityKey)
                    }
                }
            }
            return
        }
        computeSafetyNumberNow(peer, theirSigning: theirSigningB64, theirDH: theirDHB64)
    }

    /// Both halves of the peer's identity go into the code: the X25519 key is the
    /// one their messages are encrypted under.
    private func computeSafetyNumberNow(_ peer: User, theirSigning: String, theirDH: String) {
        guard let store = app.store,
              let myIdentity = try? store.identity(),
              let theirSigningData = Data(base64urlEncoded: theirSigning),
              let theirDHData = Data(base64urlEncoded: theirDH) else { return }
        safetyNumber = SafetyNumbers.generate(
            ourIdentitySigning: myIdentity.signing.publicKey.rawRepresentation,
            ourIdentityDH: myIdentity.dh.publicKey.rawRepresentation,
            ourUserId: model.ownUserId,
            theirIdentitySigning: theirSigningData, theirIdentityDH: theirDHData,
            theirUserId: peer.id)
    }
}

struct AddMembersView: View {
    let chatId: String
    let existing: Set<String>
    /// Called with the new member once the server has taken them in, so the
    /// chat can announce it.
    let onAdded: (Candidate) -> Void
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// People this device already knows: the peers of its chats. Shown before
    /// a query is typed, so the usual case, adding someone you talk to, takes
    /// one tap instead of a search.
    @State private var known: [Candidate] = []
    @State private var results: [Candidate] = []
    /// The member whose add did not go through: the row says so and stays
    /// available for another tap instead of the sheet closing on a failure.
    @State private var failedId: String?

    struct Candidate: Identifiable, Equatable {
        let id: String
        let username: String
        let displayName: String
        let avatarId: String?
    }

    private var shown: [Candidate] {
        (query.count >= 2 ? results : known).filter { !existing.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List(shown) { u in
                Button {
                    add(u)
                } label: {
                    HStack {
                        AvatarView(name: u.displayName, avatarId: u.avatarId)
                            .frame(width: 36, height: 36)
                        Text(u.displayName).foregroundStyle(.primary)
                        Text("@\(u.username)").font(.footnote).foregroundStyle(.secondary)
                        if failedId == u.id {
                            Spacer()
                            Text("Not added").font(.footnote).foregroundStyle(.red)
                        }
                    }
                }
                .accessibilityIdentifier("addMember.\(u.username)")
            }
            .searchable(text: $query)
            .onChange(of: query) { _, q in
                Task {
                    guard q.count >= 2 else { results = []; return }
                    let found = (try? await app.api.searchUsers(q)) ?? []
                    results = found.map {
                        Candidate(id: $0.id, username: $0.username, displayName: $0.display_name,
                                  avatarId: $0.avatar_id)
                    }
                }
            }
            .task { await loadKnown() }
            .navigationTitle("Add")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func loadKnown() async {
        guard let db = app.db else { return }
        let ownId = app.session?.userId ?? ""
        let users = (try? await db.read { dbc in
            try User.fetchAll(dbc, sql: """
                SELECT * FROM user WHERE id != ? AND isBlocked = 0
                ORDER BY displayName COLLATE NOCASE
                """, arguments: [ownId])
        }) ?? []
        known = users.map {
            Candidate(id: $0.id, username: $0.username, displayName: $0.displayName, avatarId: $0.avatarId)
        }
    }

    private func add(_ u: Candidate) {
        failedId = nil
        Task {
            do {
                let invited = try await app.api.updateMembers(chatId, add: [u.id], remove: [])
                if invited.contains(u.id) {
                    // their privacy keeps them out of a straight add: the
                    // invitation leaves as a message with the group's link
                    let db = await MainActor.run { AppState.shared.db }
                    let title = try? await db?.read { dbc in
                        try String.fetchOne(dbc, sql: "SELECT title FROM chat WHERE id = ?",
                                            arguments: [chatId])
                    }
                    await GroupInvites.deliver(groupChatId: chatId, title: title ?? nil, to: [u.id])
                } else {
                    onAdded(u)
                }
                dismiss()
            } catch {
                failedId = u.id
            }
        }
    }
}

#if DEBUG
/// Test data: sends messages through the regular path (real encryption, outbox,
/// server), so a large chat exercises the API the same way a person would.
extension ChatInfoView {
    var seedSection: some View {
        Section("Test data") {
            ForEach([100, 1_000, 20_000], id: \.self) { count in
                Button("Send \(count) messages") { seed(count) }
                    .disabled(seeding)
            }
            ForEach([1, 10], id: \.self) { rounds in
                Button("Send attachments ×\(rounds)") { seedAttachments(rounds) }
                    .disabled(seeding)
            }
            Button("Send albums 2/3/5/10") { seedAlbums([2, 3, 5, 10]) }
                .disabled(seeding)
            if seeding {
                HStack {
                    ProgressView()
                    Text("Sent \(seedSent)")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// One album of every listed size, to see the whole mosaic range at once.
    func seedAlbums(_ sizes: [Int]) {
        seeding = true
        seedSent = 0
        let chatId = model.chatId
        Task {
            await AttachmentSeed.sendAlbums(chatId: chatId, sizes: sizes)
            seedSent = sizes.count
            seeding = false
        }
    }

    /// One of every attachment kind, a full round per run.
    func seedAttachments(_ rounds: Int) {
        seeding = true
        seedSent = 0
        let chatId = model.chatId
        Task {
            await AttachmentSeed.send(chatId: chatId, batches: rounds)
            seedSent = rounds
            seeding = false
        }
    }

    func seed(_ count: Int) {
        seeding = true
        seedSent = 0
        let chatId = model.chatId
        Task {
            for i in 1...count {
                var content = ContentPayload(kind: "text")
                content.text = "Test message \(i) of \(count)"
                try? await app.engine?.enqueue(content: content, chatId: chatId)
                if i % 50 == 0 {
                    seedSent = i
                    // outbox drains on its own; the pause keeps the queue from
                    // outrunning the socket on large runs
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
            }
            seedSent = count
            seeding = false
        }
    }
}
#endif

extension String {
    func chunked(_ size: Int) -> [String] {
        stride(from: 0, to: count, by: size).map {
            String(Array(self)[$0..<Swift.min($0 + size, count)])
        }
    }
}
