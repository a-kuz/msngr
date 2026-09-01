import Foundation
import MsngrCore

/// Everyone's live stories, grouped by their author. A story is not encrypted:
/// who may see one is an access rule the server keeps, so the whole list comes
/// from the server and nothing of it is stored on the device.
@MainActor
final class StoriesModel: ObservableObject {
    static let shared = StoriesModel()

    @Published private(set) var stories: [APIClient.StoryDTO] = []
    @Published private(set) var loading = false

    /// Authors in the order the list shows them: the ones with something
    /// unwatched first, then by their newest story.
    var authors: [Author] {
        let byAuthor = Dictionary(grouping: stories, by: \.authorId)
        return byAuthor.values.compactMap { group -> Author? in
            guard let first = group.first else { return nil }
            let ordered = group.sorted { $0.createdAt < $1.createdAt }
            return Author(id: first.authorId, name: first.displayName,
                          avatarId: first.avatarId, stories: ordered,
                          unseen: ordered.contains { !$0.seen })
        }
        .sorted {
            if $0.unseen != $1.unseen { return $0.unseen }
            return ($0.stories.last?.createdAt ?? 0) > ($1.stories.last?.createdAt ?? 0)
        }
    }

    struct Author: Identifiable, Equatable {
        let id: String
        let name: String
        let avatarId: String?
        let stories: [APIClient.StoryDTO]
        /// Something here has not been watched: the ring around the avatar.
        let unseen: Bool
    }

    /// Whether this person has a story worth a ring right now.
    func ring(for userId: String) -> Bool {
        stories.contains { $0.authorId == userId && !$0.seen }
    }

    func hasStories(_ userId: String) -> Bool {
        stories.contains { $0.authorId == userId }
    }

    func load() async {
        // the list is asked for as soon as the chat list appears, which can be
        // before the account has finished coming up
        guard !loading, AppState.shared.ready, let api = AppState.shared.api else { return }
        loading = true
        defer { loading = false }
        stories = (try? await api.stories()) ?? stories
    }

    /// Watched: the server remembers it, and the ring goes out here without
    /// waiting for the list to be read again.
    func markSeen(_ storyId: String) async {
        guard let api = AppState.shared.api,
              let index = stories.firstIndex(where: { $0.id == storyId }), !stories[index].seen else {
            return
        }
        try? await api.markStorySeen(storyId)
        await load()
    }

    func takeDown(_ storyId: String) async {
        guard let api = AppState.shared.api else { return }
        try? await api.takeStoryDown(storyId)
        stories.removeAll { $0.id == storyId }
    }
}
