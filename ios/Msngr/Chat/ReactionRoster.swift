import SwiftUI
import MsngrCore

/// The people behind the reaction capsules of a group message, grouped by
/// emoji. A capsule tap in a group opens this as a sheet; in a direct chat the
/// capsule already says everything, so the tap keeps toggling your own
/// reaction instead.
struct ReactionRoster {
    struct Entry: Equatable, Identifiable {
        let id: String          // userId
        let name: String
        let avatarId: String?
    }
    struct Section: Equatable, Identifiable {
        let emoji: String
        let entries: [Entry]
        var id: String { emoji }
    }

    /// Sections for the sheet: the tapped emoji first, the rest by how many
    /// people chose them, ties broken by the emoji itself so the order is
    /// stable. Inside a section people stand in the order they reacted; a
    /// reactor missing from the roster (left the group) is listed under their
    /// id rather than dropped.
    static func sections(reactions: [String: [String]], users: [User],
                         tapped: String? = nil) -> [Section] {
        let byId = Dictionary(users.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return reactions
            .map { emoji, ids in
                Section(emoji: emoji, entries: ids.map { id in
                    let user = byId[id]
                    return Entry(id: id, name: user?.displayName ?? user?.username ?? id,
                                 avatarId: user?.avatarId)
                })
            }
            .sorted { a, b in
                if (a.emoji == tapped) != (b.emoji == tapped) { return a.emoji == tapped }
                if a.entries.count != b.entries.count { return a.entries.count > b.entries.count }
                return a.emoji < b.emoji
            }
    }
}

/// The capsule tap that asked for the sheet: which message and which emoji.
struct ReactionRosterRequest: Identifiable {
    let message: Message
    let emoji: String
    var id: String { message.id }
}

struct ReactionRosterSheet: View {
    let sections: [ReactionRoster.Section]

    var body: some View {
        List {
            ForEach(sections) { section in
                SwiftUI.Section {
                    ForEach(section.entries) { entry in
                        HStack(spacing: 12) {
                            AvatarView(name: entry.name, avatarId: entry.avatarId)
                                .frame(width: 36, height: 36)
                            Text(entry.name)
                            Spacer()
                        }
                        .accessibilityIdentifier("chat.reactions.person")
                    }
                } header: {
                    Text("\(section.emoji) \(section.entries.count)")
                        .font(.subheadline)
                }
            }
        }
        .listStyle(.insetGrouped)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
