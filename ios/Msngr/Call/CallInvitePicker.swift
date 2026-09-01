import SwiftUI
import GRDB
import MsngrCore

/// Picking the third person for a running call: everyone this account knows,
/// minus the people already in it.
struct CallInvitePicker: View {
    var exclude: Set<String>
    var onPick: (String) -> Void
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var users: [User] = []

    var body: some View {
        NavigationStack {
            List(users, id: \.id) { user in
                Button {
                    onPick(user.id)
                    dismiss()
                } label: {
                    HStack {
                        AvatarView(name: user.displayName, avatarId: user.avatarId)
                            .frame(width: 40, height: 40)
                        Text(user.displayName).foregroundStyle(.primary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Add to call")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        guard let db = app.db else { return }
        let excluded = exclude
        users = (try? await db.read { dbc in
            try ContactBookName.applied(dbc, to: User.fetchAll(dbc, sql: """
                SELECT u.* FROM user u
                JOIN member m ON m.userId = u.id
                JOIN chat c ON c.id = m.chatId AND c.kind = 'direct'
                GROUP BY u.id ORDER BY u.displayName
                """))
        })?.filter { !excluded.contains($0.id) } ?? []
    }
}
