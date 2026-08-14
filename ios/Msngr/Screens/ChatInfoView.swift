import SwiftUI
import MsngrCore
import MsngrCrypto

/// Инфо о чате: профиль собеседника или управление группой.
struct ChatInfoView: View {
    @ObservedObject var model: ChatViewModel
    @EnvironmentObject var app: AppState
    @State private var showAddMembers = false
    @State private var inviteLink: String?
    @State private var safetyNumber: String?
    @State private var editTitle = ""
    @State private var ttl: Int = 0

    private var isGroup: Bool { model.chat?.kind == .group }
    private var iAmAdmin: Bool {
        // роль в members-таблице
        true // упрощение: сервер всё равно проверяет права
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    AvatarView(name: model.headerTitle,
                               avatarId: isGroup ? model.chat?.avatarId : model.peer?.avatarId,
                               online: model.peer?.online ?? false)
                        .frame(width: 90, height: 90)
                    Text(model.headerTitle).font(.title2.bold())
                    Text(isGroup ? "\(model.members.count) участников"
                         : "@\(model.peer?.username ?? "")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            Section {
                Toggle(isOn: Binding(
                    get: { model.chat?.muted ?? false },
                    set: { on in
                        Task {
                            try? await app.db.write { [id = model.chatId] dbc in
                                try dbc.execute(sql: "UPDATE chat SET muted = ? WHERE id = ?", arguments: [on, id])
                            }
                            try? await app.api.setChatFlags(model.chatId, muted: on)
                        }
                    })) {
                    Label("Без звука", systemImage: "bell.slash")
                }

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
                    Button(role: .destructive) {
                        Task { try? await app.api.setBlocked(peer.id, blocked: true) }
                    } label: {
                        Label("Заблокировать", systemImage: "hand.raised")
                    }
                }
            }

            if isGroup {
                Section("Участники") {
                    ForEach(model.members) { member in
                        HStack {
                            AvatarView(name: member.displayName, avatarId: member.avatarId, online: member.online)
                                .frame(width: 36, height: 36)
                            VStack(alignment: .leading) {
                                Text(member.displayName)
                                Text("@\(member.username)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if member.id == model.chat?.createdBy {
                                Text("админ").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            if member.id != model.ownUserId {
                                Button(role: .destructive) {
                                    Task { try? await app.api.updateMembers(model.chatId, add: [], remove: [member.id]) }
                                } label: {
                                    Label("Удалить", systemImage: "person.badge.minus")
                                }
                            }
                        }
                    }
                    Button {
                        showAddMembers = true
                    } label: {
                        Label("Добавить участника", systemImage: "person.badge.plus")
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
                Section {
                    Button(role: .destructive) {
                        Task {
                            try? await app.api.leaveChat(model.chatId)
                            try? await app.db.write { [id = model.chatId] dbc in
                                try dbc.execute(sql: "DELETE FROM chat WHERE id = ?", arguments: [id])
                            }
                        }
                    } label: {
                        Label("Покинуть группу", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
        }
        .navigationTitle(isGroup ? "Группа" : "Профиль")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { ttl = model.chat?.ttlSeconds ?? 0 }
        .sheet(isPresented: $showAddMembers) {
            AddMembersView(chatId: model.chatId, existing: Set(model.members.map(\.id)))
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

extension String {
    func chunked(_ size: Int) -> [String] {
        stride(from: 0, to: count, by: size).map {
            String(Array(self)[$0..<Swift.min($0 + size, count)])
        }
    }
}
