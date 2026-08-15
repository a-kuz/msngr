import SwiftUI
import PhotosUI
import Combine
import GRDB
import MsngrCore
import MsngrCrypto

/// Роли участников чата: chat-фрейм переписывает таблицу member, наблюдение
/// держит экран в актуальном состоянии (сняли админку — поля пропали).
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

/// Инфо о чате: профиль собеседника или управление группой.
struct ChatInfoView: View {
    @ObservedObject var model: ChatViewModel
    @EnvironmentObject var app: AppState
    @StateObject private var rolesModel = ChatRolesModel()
    @State private var showAddMembers = false
    @State private var inviteLink: String?
    @State private var safetyNumber: String?
    @State private var editTitle = ""
    @State private var ttl: Int = 0
    @State private var showMuteOptions = false
    @State private var showBlockConfirm = false
    @State private var showLeaveConfirm = false
    @State private var avatarItem: PhotosPickerItem?
    @State private var savingSettings = false
    #if DEBUG
    @State var seeding = false
    @State var seedSent = 0
    #endif

    private var isGroup: Bool { model.chat?.kind == .group }
    private var myRole: String? { rolesModel.roles[model.ownUserId] }
    private var kind: ChatKind { model.chat?.kind ?? .direct }
    /// Название и аватар группы меняет только админ (сервер проверяет то же).
    private var canEditSettings: Bool {
        ChatPermissions.canEditSettings(kind: kind, role: myRole)
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
                        TextField("Название группы", text: $editTitle)
                            .font(.title3.bold())
                            .multilineTextAlignment(.center)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("chatInfo.title")
                            .onSubmit { saveTitle() }
                    } else {
                        Text(model.headerTitle).font(.title2.bold())
                    }
                    Text(isGroup ? "\(model.members.count) участников"
                         : "@\(model.peer?.username ?? "")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if isGroup && canEditSettings && titleChanged {
                        Button("Сохранить название", action: saveTitle)
                            .buttonStyle(.borderedProminent)
                            .disabled(savingSettings)
                            .accessibilityIdentifier("chatInfo.saveTitle")
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
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
                        Label("Без звука", systemImage: "bell.slash")
                        if let muteUntilLabel {
                            Text(muteUntilLabel).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("chatInfo.mute")

                Picker(selection: $ttl) {
                    Text("Выкл").tag(0)
                    Text("24 часа").tag(86400)
                    Text("7 дней").tag(604800)
                    Text("90 дней").tag(7_776_000)
                } label: {
                    Label("Автоудаление", systemImage: "timer")
                }
                .onChange(of: ttl) { _, newTTL in
                    guard newTTL != model.chat?.ttlSeconds else { return }
                    var c = ContentPayload(kind: "disappearing")
                    c.ttlSeconds = newTTL
                    model.enqueue(c)
                }
            }

            if !isGroup, let peer = model.peer {
                Section("Безопасность") {
                    Button {
                        computeSafetyNumber(peer)
                    } label: {
                        Label("Код безопасности", systemImage: "checkmark.shield")
                    }
                    if let sn = safetyNumber {
                        Text(sn.chunked(5).joined(separator: "  "))
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Button(role: peer.isBlocked ? .none : .destructive) {
                        showBlockConfirm = true
                    } label: {
                        Label(peer.isBlocked ? "Разблокировать" : "Заблокировать",
                              systemImage: peer.isBlocked ? "hand.raised.slash" : "hand.raised")
                    }
                    .accessibilityIdentifier("chatInfo.block")
                }
            }

            if isGroup {
                Section("Участники") {
                    ForEach(model.members) { member in
                        memberRow(member)
                    }
                    if ChatPermissions.canAddMembers(kind: kind, role: myRole) {
                        Button {
                            showAddMembers = true
                        } label: {
                            Label("Добавить участника", systemImage: "person.badge.plus")
                        }
                    }
                    Button {
                        Task {
                            if let inv = try? await app.api.createInvite(model.chatId) {
                                inviteLink = inv.link
                                UIPasteboard.general.string = inv.link
                            }
                        }
                    } label: {
                        Label(inviteLink == nil ? "Ссылка-приглашение" : "Скопировано!",
                              systemImage: "link")
                    }
                }
                if ChatPermissions.canLeave(kind: kind, role: myRole) {
                    Section {
                        Button(role: .destructive) {
                            showLeaveConfirm = true
                        } label: {
                            Label("Покинуть группу", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        .accessibilityIdentifier("chatInfo.leave")
                    }
                }
            }
            #if DEBUG
            seedSection
            #endif
        }
        .navigationTitle(isGroup ? "Группа" : "Профиль")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            ttl = model.chat?.ttlSeconds ?? 0
            editTitle = model.chat?.title ?? ""
            rolesModel.start(chatId: model.chatId, db: app.db)
        }
        // название могло смениться на другом устройстве, пока экран открыт
        .onChange(of: model.chat?.title) { _, new in
            if !titleChanged || editTitle.isEmpty { editTitle = new ?? "" }
        }
        .task { await app.engine?.refreshBlocked() }
        .sheet(isPresented: $showAddMembers) {
            AddMembersView(chatId: model.chatId, existing: Set(model.members.map(\.id)))
        }
        .confirmationDialog("Без звука", isPresented: $showMuteOptions, titleVisibility: .visible) {
            ForEach(MuteOption.allCases, id: \.self) { option in
                Button(option.title) { applyMute(option) }
            }
            Button("Отмена", role: .cancel) {}
        }
        .confirmationDialog(blockConfirmTitle, isPresented: $showBlockConfirm, titleVisibility: .visible) {
            let blocked = model.peer?.isBlocked ?? false
            Button(blocked ? "Разблокировать" : "Заблокировать",
                   role: blocked ? .none : .destructive) {
                toggleBlock()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(model.peer?.isBlocked ?? false
                 ? "Собеседник снова сможет писать вам."
                 : "Собеседник не сможет писать вам, а его сообщения не будут доставляться.")
        }
        .confirmationDialog("Покинуть группу?", isPresented: $showLeaveConfirm, titleVisibility: .visible) {
            Button("Покинуть", role: .destructive) { leaveGroup() }
            Button("Отмена", role: .cancel) {}
        }
        .onChange(of: avatarItem) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let prepared = ImageProcessor.prepareForSending(data, maxDimension: 640) else { return }
                _ = try? await app.api.uploadChatAvatar(chatId: model.chatId, jpeg: prepared.data)
            }
        }
    }

    /// Аватар чата: у админа группы — кнопка выбора фото, у остальных просто картинка.
    @ViewBuilder
    private var groupAvatar: some View {
        let avatar = AvatarView(name: model.headerTitle,
                                avatarId: isGroup ? model.chat?.avatarId : model.peer?.avatarId,
                                online: model.peer?.online ?? false)
            .frame(width: 90, height: 90)
        if isGroup && canEditSettings {
            PhotosPicker(selection: $avatarItem, matching: .images) {
                avatar.overlay(alignment: .bottomTrailing) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Theme.accent, in: Circle())
                }
            }
            .accessibilityIdentifier("chatInfo.avatar")
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
                Text("админ").font(.caption).foregroundStyle(.secondary)
            }
        }
        .swipeActions {
            if member.id != model.ownUserId,
               ChatPermissions.canRemoveMembers(kind: kind, role: myRole) {
                Button(role: .destructive) {
                    Task { try? await app.api.updateMembers(model.chatId, add: [], remove: [member.id]) }
                } label: {
                    Label("Удалить", systemImage: "person.badge.minus")
                }
            }
            if member.id != model.ownUserId,
               ChatPermissions.canManageAdmins(kind: kind, role: myRole) {
                let isAdmin = role == ChatPermissions.adminRole
                Button {
                    Task { try? await app.api.setAdmin(model.chatId, userId: member.id, admin: !isAdmin) }
                } label: {
                    Label(isAdmin ? "Снять админа" : "Сделать админом",
                          systemImage: isAdmin ? "person.badge.minus" : "star")
                }
                .tint(.orange)
            }
        }
    }

    private var titleChanged: Bool {
        editTitle != (model.chat?.title ?? "")
            && !editTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var blockConfirmTitle: String {
        (model.peer?.isBlocked ?? false ? "Разблокировать " : "Заблокировать ")
            + (model.peer?.displayName ?? "")
    }

    private func saveTitle() {
        let title = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != model.chat?.title else { return }
        savingSettings = true
        Task {
            try? await app.api.chatSettings(model.chatId, title: title)
            savingSettings = false
        }
    }

    /// nil — снять mute; иначе включить на срок опции.
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

    private func leaveGroup() {
        Task {
            try? await app.api.leaveChat(model.chatId)
            try? await app.db.write { [id = model.chatId] dbc in
                try dbc.execute(sql: "DELETE FROM chat WHERE id = ?", arguments: [id])
            }
        }
    }

    private func computeSafetyNumber(_ peer: User) {
        guard let store = app.store,
              let myIdentity = try? store.identity(),
              let theirKeyB64 = peer.identitySigning,
              let theirKey = Data(base64urlEncoded: theirKeyB64) else {
            // ключ собеседника подтянем из prekey-бандла
            Task {
                if let bundles = try? await app.api.prekeys(userId: peer.id).bundles, let b = bundles.first {
                    try? await app.db.write { dbc in
                        try dbc.execute(sql: "UPDATE user SET identitySigning = ?, identityDH = ? WHERE id = ?",
                                        arguments: [b.identitySignKey, b.identityKey, peer.id])
                    }
                    await MainActor.run { computeSafetyNumberNow(peer, theirKey: b.identitySignKey) }
                }
            }
            return
        }
        safetyNumber = SafetyNumbers.generate(
            ourIdentitySigning: myIdentity.signing.publicKey.rawRepresentation,
            ourUserId: model.ownUserId,
            theirIdentitySigning: theirKey, theirUserId: peer.id)
    }

    private func computeSafetyNumberNow(_ peer: User, theirKey: String) {
        guard let store = app.store,
              let myIdentity = try? store.identity(),
              let theirKeyData = Data(base64urlEncoded: theirKey) else { return }
        safetyNumber = SafetyNumbers.generate(
            ourIdentitySigning: myIdentity.signing.publicKey.rawRepresentation,
            ourUserId: model.ownUserId,
            theirIdentitySigning: theirKeyData, theirUserId: peer.id)
    }
}

struct AddMembersView: View {
    let chatId: String
    let existing: Set<String>
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [APIClient.UserDTO] = []

    var body: some View {
        NavigationStack {
            List(results.filter { !existing.contains($0.id) }, id: \.id) { u in
                Button {
                    Task {
                        try? await app.api.updateMembers(chatId, add: [u.id], remove: [])
                        dismiss()
                    }
                } label: {
                    HStack {
                        AvatarView(name: u.display_name, avatarId: u.avatar_id)
                            .frame(width: 36, height: 36)
                        Text(u.display_name).foregroundStyle(.primary)
                        Text("@\(u.username)").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $query)
            .onChange(of: query) { _, q in
                Task { results = q.count >= 2 ? ((try? await app.api.searchUsers(q)) ?? []) : [] }
            }
            .navigationTitle("Добавить")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#if DEBUG
/// Test data: sends messages through the regular path (real encryption, outbox,
/// server), so a large chat exercises the API the same way a person would.
extension ChatInfoView {
    var seedSection: some View {
        Section("Тестовые данные") {
            ForEach([100, 1_000, 20_000], id: \.self) { count in
                Button("Отправить \(count) сообщений") { seed(count) }
                    .disabled(seeding)
            }
            if seeding {
                HStack {
                    ProgressView()
                    Text("Отправлено \(seedSent)")
                        .foregroundStyle(.secondary)
                }
            }
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
