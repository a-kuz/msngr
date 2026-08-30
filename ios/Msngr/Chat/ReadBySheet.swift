import SwiftUI
import MsngrCore

/// Who has read and who has only received one outgoing group message, split
/// from the per-member marks the receipts keep in `chatMark`.
enum ReadByRoster {
    /// Members with a read mark at or past the seq go into the first list,
    /// members who merely have the message into the second; the sender and
    /// anyone the message has not reached are in neither.
    static func split(seq: Int, members: [User], marks: [String: MemberMark],
                      ownUserId: String) -> (read: [User], delivered: [User]) {
        var read: [User] = []
        var delivered: [User] = []
        for member in members where member.id != ownUserId {
            guard let mark = marks[member.id] else { continue }
            if mark.readUpTo >= seq {
                read.append(member)
            } else if mark.deliveredUpTo >= seq {
                delivered.append(member)
            }
        }
        let byName: (User, User) -> Bool = {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        return (read.sorted(by: byName), delivered.sorted(by: byName))
    }
}

/// Opened from the context menu of an outgoing message in a group.
struct ReadBySheet: View {
    let message: Message
    @ObservedObject var model: ChatViewModel

    @State private var read: [User] = []
    @State private var delivered: [User] = []
    @State private var loaded = false

    var body: some View {
        List {
            if loaded && read.isEmpty && delivered.isEmpty {
                Text("No one has received this yet")
                    .foregroundStyle(.secondary)
            }
            if !read.isEmpty {
                Section {
                    ForEach(read) { user in row(user) }
                } header: {
                    Text("Read by \(read.count)")
                }
            }
            if !delivered.isEmpty {
                Section {
                    ForEach(delivered) { user in row(user) }
                } header: {
                    Text("Delivered to \(delivered.count)")
                }
            }
        }
        .listStyle(.insetGrouped)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await load() }
    }

    private func row(_ user: User) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: user.displayName, avatarId: user.avatarId)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading) {
                Text(user.displayName)
                Text("@\(user.username)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityIdentifier("chat.readBy.person")
    }

    private func load() async {
        guard let seq = message.seq, let db = AppState.shared.db else { return }
        let chatId = message.chatId
        let ownUserId = model.ownUserId
        let marks = (try? await db.read { dbc in
            try SyncEngine.memberMarks(dbc, chatId: chatId, ownUserId: ownUserId)
        }) ?? [:]
        (read, delivered) = ReadByRoster.split(seq: seq, members: model.members,
                                               marks: marks, ownUserId: ownUserId)
        loaded = true
    }
}
