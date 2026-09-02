import SwiftUI
import AVFoundation
import MsngrCore

/// Watching stories: one author fills the screen, and a horizontal swipe pages
/// to the next author — both pages move together under the finger, each
/// already showing its frame, the one leaving shrinking and dimming a little.
/// A pull down shrinks the viewer towards the list behind it and closes it.
/// Within an author a tap on the right half moves on, a tap on the left goes
/// back, and a finger held anywhere stops the clock until it is lifted. What
/// follows is fetched ahead of the clock: the rest of the author's frames and
/// the neighbouring authors' first.
struct StoryViewerView: View {
    let authors: [StoriesModel.Author]
    let start: StoriesModel.Author
    var onFinished: () -> Void

    @State private var position: String?
    @StateObject private var preloader = StoryPreloader()
    /// How far a finger has pulled the viewer down towards closing it.
    @State private var pull: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(authors) { author in
                        StoryAuthorPage(author: author,
                                        active: position == author.id,
                                        preloader: preloader,
                                        onNext: { advance(from: author) },
                                        onPrevious: { retreat(from: author) },
                                        onClose: onFinished)
                            .containerRelativeFrame([.horizontal, .vertical])
                            .clipShape(RoundedRectangle(cornerRadius: pull > 0 ? 24 : 0, style: .continuous))
                            // the page under the finger shrinks a little and
                            // dims as it leaves, and the next one grows in
                            .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                content
                                    .scaleEffect(1 - abs(phase.value) * 0.08)
                                    .brightness(-abs(phase.value) * 0.35)
                            }
                            .id(author.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $position)
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            // pulled down, the viewer shrinks towards the list behind it and
            // lets go past a third of the way
            .scaleEffect(1 - min(pull, geo.size.height) / geo.size.height * 0.35, anchor: .center)
            .offset(y: pull)
            .clipShape(RoundedRectangle(cornerRadius: pull > 0 ? 32 : 0, style: .continuous))
            .simultaneousGesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .global)
                    .onChanged { value in
                        guard value.translation.height > 0,
                              abs(value.translation.height) > abs(value.translation.width) * 1.5 || pull > 0
                        else { return }
                        pull = value.translation.height
                    }
                    .onEnded { value in
                        guard pull > 0 else { return }
                        if pull > geo.size.height / 3 || value.predictedEndTranslation.height > geo.size.height / 2 {
                            withAnimation(.easeOut(duration: 0.2)) { pull = geo.size.height }
                            onFinished()
                        } else {
                            withAnimation(.spring(duration: 0.35)) { pull = 0 }
                        }
                    }
            )
        }
        .background(Color.black.opacity(pull > 0 ? 0 : 1))
        .ignoresSafeArea()
        .statusBarHidden()
        .onAppear {
            position = start.id
            prefetchNeighbour(of: start)
        }
        .onChange(of: position) { _, id in
            guard let author = authors.first(where: { $0.id == id }) else { return }
            prefetchNeighbour(of: author)
        }
        .accessibilityIdentifier("story.viewer")
    }

    private func index(of author: StoriesModel.Author) -> Int? {
        authors.firstIndex { $0.id == author.id }
    }

    /// The author's frames ran out: the next page slides up, or the viewer closes.
    private func advance(from author: StoriesModel.Author) {
        guard let i = index(of: author), i + 1 < authors.count else {
            onFinished()
            return
        }
        withAnimation(.spring(duration: 0.4)) { position = authors[i + 1].id }
    }

    private func retreat(from author: StoriesModel.Author) {
        guard let i = index(of: author), i > 0 else { return }
        withAnimation(.spring(duration: 0.4)) { position = authors[i - 1].id }
    }

    /// The next author's first frame is on disk before the swipe starts.
    private func prefetchNeighbour(of author: StoriesModel.Author) {
        guard let i = index(of: author) else { return }
        if i + 1 < authors.count, let first = authors[i + 1].stories.first?.frames.first {
            preloader.prefetch([first])
        }
        if i > 0, let first = authors[i - 1].stories.first?.frames.first {
            preloader.prefetch([first])
        }
    }
}

/// Fetches story frames ahead of the clock, each once, and never more than a
/// few at a time — the frame on screen keeps the network first.
@MainActor
final class StoryPreloader: ObservableObject {
    private var inFlight: Set<String> = []
    private var done: Set<String> = []

    func prefetch(_ frames: [APIClient.StoryFrame]) {
        guard let media = AppState.shared.media else { return }
        for frame in frames where !done.contains(frame.mediaId) && !inFlight.contains(frame.mediaId) {
            inFlight.insert(frame.mediaId)
            Task(priority: .utility) {
                _ = try? await media.fetchPlain(mediaId: frame.mediaId,
                                                mime: frame.type == "video" ? "video/mp4" : "image/jpeg")
                inFlight.remove(frame.mediaId)
                done.insert(frame.mediaId)
            }
        }
    }
}

/// One author's stories, frame after frame without a seam between stories.
struct StoryAuthorPage: View {
    let author: StoriesModel.Author
    /// This page is the one on screen: its clock runs and its clip plays.
    let active: Bool
    let preloader: StoryPreloader
    var onNext: () -> Void
    var onPrevious: () -> Void
    var onClose: () -> Void

    @EnvironmentObject var app: AppState
    @ObservedObject private var model = StoriesModel.shared

    @State private var index = 0
    @State private var progress: Double = 0
    @State private var held = false
    @State private var showActions = false
    /// The reply is being typed: the frame waits for it.
    @FocusState private var replyFocused: Bool
    @State private var frameURL: URL?
    @State private var reply = ""
    @State private var showViewers = false
    @State private var link: String?
    @State private var started = false

    /// How long one frame stands before the next one comes up.
    private static let frameSeconds: Double = 5
    private let tick = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    /// Every frame this author has live, in order.
    private var slides: [(story: APIClient.StoryDTO, frame: APIClient.StoryFrame)] {
        author.stories.flatMap { story in story.frames.map { (story, $0) } }
    }
    private var slide: (story: APIClient.StoryDTO, frame: APIClient.StoryFrame)? {
        index < slides.count ? slides[index] : nil
    }
    private var story: APIClient.StoryDTO? { slide?.story }
    private var isMine: Bool { author.id == app.session?.userId }

    var body: some View {
        ZStack {
            Color.black
            GeometryReader { geo in
                ZStack {
                    if let frameURL, slide?.frame.type == "video" {
                        StoryVideoPlayer(url: frameURL, paused: paused || !active)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .accessibilityIdentifier("story.frame")
                    } else if let frameURL, let image = UIImage(contentsOfFile: frameURL.path) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            .blur(radius: 40)
                            .opacity(0.7)
                            .accessibilityHidden(true)
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .accessibilityIdentifier("story.frame")
                    } else {
                        ProgressView().tint(.white)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
            }
            taps
            VStack(spacing: 0) {
                bars
                header
                Spacer()
                footer
            }
        }
        .task(id: "\(index)-\(active)") { await showFrame() }
        .onReceive(tick) { _ in advanceClock() }
        .onChange(of: active) { _, isActive in
            if isActive {
                progress = 0
                if !started {
                    started = true
                    index = firstUnseen
                }
            }
        }
        .onAppear {
            if active { started = true; index = firstUnseen }
        }
    }

    /// Where watching begins: the first frame of the first story not yet seen.
    private var firstUnseen: Int {
        var offset = 0
        for story in author.stories {
            if !story.seen { return offset }
            offset += story.frames.count
        }
        return 0
    }

    private var taps: some View {
        HStack(spacing: 0) {
            Color.clear.contentShape(Rectangle())
                .onTapGesture { step(-1) }
                .accessibilityIdentifier("story.back")
            Color.clear.contentShape(Rectangle())
                .onTapGesture { step(1) }
                .accessibilityIdentifier("story.forward")
        }
        // a finger held anywhere stops the clock: the frame stays for as long
        // as it is wanted, and the swipe to the next author still goes through
        .onLongPressGesture(minimumDuration: 0.2, maximumDistance: 30) {} onPressingChanged: { down in
            held = down
        }
    }

    private var bars: some View {
        HStack(spacing: 4) {
            ForEach(slides.indices, id: \.self) { i in
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.3))
                        Capsule().fill(.white)
                            .frame(width: geo.size.width * (i < index ? 1 : i == index ? progress : 0))
                    }
                }
                .frame(height: 3)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    private var header: some View {
        HStack(spacing: 10) {
            AvatarView(name: author.name, avatarId: author.avatarId)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(author.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                if let story {
                    Text(StoryTime.ago(story.createdAt))
                        .font(.caption2).foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer()
            if isMine {
                Button { showActions = true } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("story.menu")
            }
            Button { onClose() } label: {
                Image(systemName: "xmark").foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("story.close")
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .sheet(isPresented: $showViewers) {
            if let story { StoryViewersSheet(storyId: story.id) }
        }
        // the author's own actions; the clock stands while they are open
        .confirmationDialog("", isPresented: $showActions) {
            if let story {
                Button(String(localized: "Who watched")) { showViewers = true }
                if let live = link ?? story.link {
                    Button(String(localized: "Copy link")) {
                        UIPasteboard.general.string = live
                        Haptics.success()
                    }
                    Button(String(localized: "Revoke the link"), role: .destructive) {
                        Task { link = try? await app.api.setStoryLink(story.id, open: false) }
                    }
                } else {
                    Button(String(localized: "Make a link")) {
                        Task { link = try? await app.api.setStoryLink(story.id, open: true) }
                    }
                }
                Button(String(localized: "Take it down"), role: .destructive) {
                    Task {
                        await model.takeDown(story.id)
                        onClose()
                    }
                }
            }
        }
    }

    /// The clock stands while a finger is down or something of the author's
    /// is open over the frame.
    private var paused: Bool { held || showActions || showViewers || replyFocused }

    @ViewBuilder
    private var footer: some View {
        if !isMine {
            HStack(spacing: 10) {
                TextField("Reply…", text: $reply)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.15), in: Capsule())
                    .foregroundStyle(.white)
                    .focused($replyFocused)
                    .accessibilityIdentifier("story.reply")
                Button {
                    Task { await sendReply() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                }
                .disabled(reply.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("story.replySend")
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 18)
        }
    }

    /// A picture stands for a fixed few seconds; a video stands for as long
    /// as it plays.
    private var slideSeconds: Double {
        if slide?.frame.type == "video", let dur = slide?.frame.dur, dur > 0 { return dur }
        return Self.frameSeconds
    }

    /// The clock runs only on the page on screen, and only once its frame is
    /// there to be looked at.
    private func advanceClock() {
        guard active, !paused, story != nil, frameURL != nil else { return }
        progress += 0.05 / slideSeconds
        if progress >= 1 { step(1) }
    }

    private func step(_ delta: Int) {
        let next = index + delta
        guard next >= 0 else {
            onPrevious()
            return
        }
        guard next < slides.count else {
            onNext()
            return
        }
        progress = 0
        index = next
    }

    private func showFrame() async {
        progress = 0
        frameURL = nil
        guard let slide, let media = app.media else { return }
        // a story's bytes were never encrypted: the frame comes back as it lies
        frameURL = try? await media.fetchPlain(mediaId: slide.frame.mediaId,
                                               mime: slide.frame.type == "video" ? "video/mp4" : "image/jpeg")
        guard active else { return }
        // what follows this frame is fetched while it stands
        preloader.prefetch(Array(slides[(index + 1)...].prefix(3).map(\.frame)))
        await model.markSeen(slide.story.id)
    }

    /// Answering a story goes into the direct chat with its author, quoting
    /// nothing: the story is not a message and has no seq to reply to.
    private func sendReply() async {
        let text = reply.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let chatId = await DirectChat.open(userId: author.id) else { return }
        var content = ContentPayload(kind: "text")
        content.text = text
        try? await app.engine.enqueue(content: content, chatId: chatId)
        reply = ""
    }
}

/// Who watched one story. The author's alone — nobody else is offered it, and
/// the public page counts nothing.
struct StoryViewersSheet: View {
    let storyId: String
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var viewers: [APIClient.StoryViewer] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List(viewers) { viewer in
                HStack(spacing: 10) {
                    AvatarView(name: viewer.display_name, avatarId: viewer.avatar_id)
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading) {
                        Text(viewer.display_name)
                        Text(StoryTime.ago(viewer.seen_at))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if loaded && viewers.isEmpty {
                    ContentUnavailableView("Nobody yet", systemImage: "eye.slash")
                }
            }
            .navigationTitle("Who watched")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .task {
                viewers = (try? await app.api.storyViewers(storyId)) ?? []
                loaded = true
            }
        }
    }
}

/// A story's video with no controls over it. Paused, it stands on its first
/// frame — which is what the next page shows while the swipe is under way —
/// and plays from the start the moment its page is the one on screen.
struct StoryVideoPlayer: UIViewRepresentable {
    let url: URL
    let paused: Bool

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.load(url)
        if !paused { view.player.play() }
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        if view.url != url { view.load(url) }
        if paused {
            view.player.pause()
        } else if view.player.rate == 0 {
            view.player.play()
        }
    }

    final class PlayerView: UIView {
        let player = AVPlayer()
        private(set) var url: URL?
        override class var layerClass: AnyClass { AVPlayerLayer.self }

        func load(_ url: URL) {
            self.url = url
            let layer = layer as! AVPlayerLayer
            layer.player = player
            layer.videoGravity = .resizeAspect
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
        }
    }
}

enum StoryTime {
    /// How long ago, in the units a story lives by.
    static func ago(_ millis: Double, now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince1970 - millis / 1000
        if elapsed < 60 { return String(localized: "just now") }
        if elapsed < 3600 { return String(localized: "\(Int(elapsed / 60)) min ago") }
        return String(localized: "\(Int(elapsed / 3600)) h ago")
    }
}
