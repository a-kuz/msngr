import Foundation
import MsngrCore

/// Everyone's live stories, grouped by their author. A story is not encrypted:
/// who may see one is an access rule the server keeps, so the list comes from
/// the server and nothing of it is stored on the device. Every sync is
/// answered with the whole inbox, and from there the list follows the socket:
/// a story delivered, taken down, its counts moved or this user's own watch
/// made elsewhere arrives as a frame. The list is never asked for.
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

    /// The ring around this person's picture: one flag per live story in the
    /// order they were published, whether it has been watched. Nil with
    /// nothing live.
    func ring(for userId: String) -> [Bool]? {
        let own = stories.filter { $0.authorId == userId }.sorted { $0.createdAt < $1.createdAt }
        return own.isEmpty ? nil : own.map(\.seen)
    }

    /// Keeps the list in step with the engine until the returned task is
    /// cancelled. The subscription is taken here, synchronously, so a frame
    /// sent the moment the socket opens is not missed: every sync is answered
    /// with the whole inbox — a frame sent while the socket was down is gone,
    /// and the server's inbox is the truth — and the frames in between are
    /// applied one by one. Nothing is asked for.
    @discardableResult
    func follow(_ engine: SyncEngine) -> Task<Void, Never> {
        let frames = engine.storyStream.subscribe()
        return Task { @MainActor [weak self] in
            for await frame in frames {
                guard let self else { return }
                self.apply(frame)
            }
        }
    }

    private func apply(_ f: WSIncoming) {
        if f.t == "stories", let list = f.stories {
            stories = list
            return
        }
        guard let storyId = f.storyId else { return }
        switch f.event {
        case "new":
            guard let story = f.story else { return }
            if let i = stories.firstIndex(where: { $0.id == storyId }) {
                stories[i] = story
            } else {
                stories.append(story)
                stories.sort { $0.createdAt < $1.createdAt }
            }
        case "removed":
            stories.removeAll { $0.id == storyId }
        case "stats":
            guard let i = stories.firstIndex(where: { $0.id == storyId }) else { return }
            stories[i].views = f.views ?? stories[i].views
            stories[i].likes = f.likes ?? stories[i].likes
        case "mark":
            guard let i = stories.firstIndex(where: { $0.id == storyId }) else { return }
            if let seen = f.seen { stories[i].seen = seen }
            if let liked = f.liked { stories[i].liked = liked }
        default:
            break
        }
    }

    /// The whole list asked for outright: only for a story named by a reply
    /// before the inbox has arrived on this connection.
    func load() async {
        guard !loading, AppState.shared.ready, let api = AppState.shared.api else { return }
        loading = true
        defer { loading = false }
        stories = (try? await api.stories()) ?? stories
    }

    /// Watched: the ring goes out here at once, and the server remembers it
    /// behind the frame — the author's counts move through their own socket.
    func markSeen(_ storyId: String) async {
        guard let api = AppState.shared.api,
              let index = stories.firstIndex(where: { $0.id == storyId }), !stories[index].seen,
              stories[index].authorId != AppState.shared.session?.userId else {
            return
        }
        stories[index].seen = true
        for attempt in 0..<3 {
            if (try? await api.markStorySeen(storyId)) != nil { return }
            try? await Task.sleep(for: .seconds(1 << attempt))
        }
    }

    /// A heart on someone's story, on or off. The heart shows at once and the
    /// server is told behind it, a few times over if it has to be; only a
    /// refusal that outlasts the retries takes the heart back.
    func like(_ storyId: String, on: Bool) async {
        guard let api = AppState.shared.api,
              let index = stories.firstIndex(where: { $0.id == storyId }),
              stories[index].authorId != AppState.shared.session?.userId else {
            return
        }
        stories[index].liked = on
        stories[index].seen = true
        for attempt in 0..<3 {
            if (try? await api.likeStory(storyId, on: on)) != nil { return }
            try? await Task.sleep(for: .seconds(1 << attempt))
        }
        if let index = stories.firstIndex(where: { $0.id == storyId }) {
            stories[index].liked = !on
        }
    }

    func takeDown(_ storyId: String) async {
        guard let api = AppState.shared.api else { return }
        stories.removeAll { $0.id == storyId }
        try? await api.takeStoryDown(storyId)
    }
}
