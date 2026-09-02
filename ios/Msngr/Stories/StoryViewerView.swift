import SwiftUI
import AVFoundation
import MsngrCore

/// Watching stories: one author fills the screen, and a horizontal swipe pages
/// to the next author — the pages are the faces of a cube turning under the
/// finger, each already showing its frame, the face turned away in shadow.
/// A pull down shrinks the viewer towards the list behind it and closes it.
/// Within an author a tap on the right half moves on, a tap on the left goes
/// back, and a finger held anywhere stops the clock until it is lifted. What
/// follows is fetched ahead of the clock: the rest of the author's frames and
/// the neighbouring authors' first.
struct StoryViewerView: View {
    let authors: [StoriesModel.Author]
    let start: StoriesModel.Author
    /// The story to stand on first, when the viewer was opened on one in
    /// particular; otherwise the author's first story not yet seen.
    var startStoryId: String? = nil
    var onFinished: () -> Void

    @State private var position: String?
    @StateObject private var preloader = StoryPreloader()
    /// How far a finger has pulled the viewer down towards closing it.
    @State private var pull: CGFloat = 0
    /// The pages are moving between authors: no frame's clock runs meanwhile.
    @State private var turning = false

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(authors) { author in
                        StoryAuthorPage(author: author,
                                        active: position == author.id,
                                        turning: turning,
                                        startStoryId: author.id == start.id ? startStoryId : nil,
                                        preloader: preloader,
                                        onNext: { advance(from: author) },
                                        onPrevious: { retreat(from: author) },
                                        onClose: onFinished)
                            .containerRelativeFrame([.horizontal, .vertical])
                            .clipShape(RoundedRectangle(cornerRadius: pull > 0 ? 24 : 0, style: .continuous))
                            // the pages are the faces of a cube turning under
                            // the finger: the one leaving hinges on the screen
                            // edge it leaves by and swings into depth, the next
                            // swings in on the other edge, and the face turned
                            // away is in shadow
                            .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                content
                                    // the page gone off to the left is at a
                                    // negative phase: it hinges on its trailing
                                    // edge, where it meets the next page, and its
                                    // free edge swings back; the page coming in
                                    // from the right hinges on its leading edge
                                    .rotation3DEffect(.degrees(phase.value * 90),
                                                      axis: (x: 0, y: 1, z: 0),
                                                      anchor: phase.value < 0 ? .trailing : .leading,
                                                      perspective: 0.4)
                                    .brightness(-abs(phase.value) * 0.5)
                            }
                            .id(author.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $position)
            // the clock stands still while the cube is turning under the finger
            .onScrollPhaseChange { _, phase in turning = phase != .idle }
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
    /// The viewer is mid-swipe between authors: the clock waits.
    var turning = false
    /// The story to open on, when the viewer was asked for one in particular.
    var startStoryId: String? = nil
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
    /// The picture of the frame, decoded once when it arrives.
    @State private var image: UIImage?
    @State private var reply = ""
    @State private var showViewers = false
    @State private var link: String?
    @State private var started = false
    /// The heart swelling for a moment after it is tapped.
    @State private var heartPop = false
    /// A reply just went out: the word shows for a moment over the field.
    @State private var sentToast = false

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
    /// The story as the list knows it now: its heart and its counts move
    /// while the page stands.
    private var live: APIClient.StoryDTO? {
        guard let story else { return nil }
        return model.stories.first { $0.id == story.id } ?? story
    }
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
                    } else if let image {
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
                    }
                    if frameURL == nil {
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
        // the frame is fetched once per slide; whether the page is the active
        // one changes what is done around it, never what it shows — a page
        // swiped past keeps its picture instead of flashing a spinner
        .task(id: index) { await showFrame() }
        .task(id: "\(index)-\(active)-\(frameURL?.path ?? "")") { await frameShown() }
        .onReceive(tick) { _ in advanceClock() }
        .onChange(of: active) { _, isActive in
            if isActive {
                progress = 0
                if !started {
                    started = true
                    index = startIndex
                }
            }
        }
        .onAppear {
            if active { started = true; index = startIndex }
        }
    }

    /// Where watching begins: the story the viewer was opened on, or else the
    /// first frame of the first story not yet seen.
    private var startIndex: Int {
        var offset = 0
        if let startStoryId {
            for story in author.stories {
                if story.id == startStoryId { return offset }
                offset += story.frames.count
            }
            offset = 0
        }
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
    private var paused: Bool { held || turning || showActions || showViewers || replyFocused }

    /// Under the frame: the author's counts, or a viewer's reply field with
    /// the heart beside it.
    @ViewBuilder
    private var footer: some View {
        if isMine {
            if let live {
                Button { showViewers = true } label: {
                    HStack(spacing: 16) {
                        Label(CountFormatter.short(live.views ?? 0), systemImage: "eye.fill")
                            .accessibilityIdentifier("story.views")
                        if let likes = live.likes, likes > 0 {
                            Label(CountFormatter.short(likes), systemImage: "heart.fill")
                                .accessibilityIdentifier("story.likes")
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.15), in: Capsule())
                }
                .accessibilityIdentifier("story.counts")
                .padding(.bottom, 18)
            }
        } else {
            HStack(spacing: 10) {
                TextField("Reply…", text: $reply)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.15), in: Capsule())
                    .foregroundStyle(.white)
                    .focused($replyFocused)
                    .submitLabel(.send)
                    .onSubmit { Task { await sendReply() } }
                    .overlay(alignment: .leading) {
                        if sentToast {
                            Text("Sent")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(.white.opacity(0.25), in: Capsule())
                                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                                .accessibilityIdentifier("story.sent")
                        }
                    }
                    .accessibilityIdentifier("story.reply")
                if reply.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button { toggleHeart() } label: {
                        Image(systemName: live?.liked == true ? "heart.fill" : "heart")
                            .font(.title2)
                            .foregroundStyle(live?.liked == true ? .red : .white)
                            .scaleEffect(heartPop ? 1.35 : 1)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("story.like")
                    .accessibilityValue(live?.liked == true ? "1" : "0")
                } else {
                    Button {
                        Task { await sendReply() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                    }
                    .accessibilityIdentifier("story.replySend")
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 18)
        }
    }

    /// The heart goes on or comes off at once, with a swell and a tap of the
    /// engine; the server hears about it behind.
    private func toggleHeart() {
        guard let live else { return }
        let on = !live.liked
        if on { Haptics.light() }
        withAnimation(.spring(duration: 0.3, bounce: 0.5)) { heartPop = true }
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            withAnimation(.spring(duration: 0.3)) { heartPop = false }
        }
        Task { await model.like(live.id, on: on) }
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
        image = nil
        guard let slide, let media = app.media else { return }
        // a story's bytes were never encrypted: the frame comes back as it lies
        let url = try? await media.fetchPlain(mediaId: slide.frame.mediaId,
                                              mime: slide.frame.type == "video" ? "video/mp4" : "image/jpeg")
        guard !Task.isCancelled else { return }
        if let url, slide.frame.type != "video" {
            // decoded once, off the main thread: the body is drawn on every
            // tick of a swipe and must not open the file each time
            let path = url.path
            image = await Task.detached(priority: .userInitiated) {
                UIImage(contentsOfFile: path)?.preparingForDisplay()
            }.value
        }
        guard !Task.isCancelled else { return }
        frameURL = url
    }

    /// What a frame standing on the active page sets in motion.
    private func frameShown() async {
        guard active, frameURL != nil, let slide else { return }
        // what follows this frame is fetched while it stands
        preloader.prefetch(Array(slides[(index + 1)...].prefix(3).map(\.frame)))
        // the author's own counts move by frames from their object as people
        // watch; only someone else's story has a watch to record
        if !isMine {
            await model.markSeen(slide.story.id)
        }
    }

    /// Answering a story goes into the direct chat with its author as a text
    /// carrying the story: the chat draws the frame over the words and opens
    /// the story from it. The field empties at once and says «Sent» for a
    /// moment; the send itself is the engine's, with its own retries.
    private func sendReply() async {
        let text = reply.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let slide else { return }
        reply = ""
        replyFocused = false
        withAnimation(.spring(duration: 0.3)) { sentToast = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeOut(duration: 0.25)) { sentToast = false }
        }
        guard let chatId = await DirectChat.open(userId: author.id) else { return }
        var content = ContentPayload(kind: "text")
        content.text = text
        content.story = StoryRef(storyId: slide.story.id, authorId: slide.story.authorId,
                                 mediaId: slide.frame.mediaId, type: slide.frame.type,
                                 w: slide.frame.w, h: slide.frame.h,
                                 expiresAt: slide.story.expiresAt)
        try? await app.engine.enqueue(content: content, chatId: chatId)
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
                    Spacer()
                    if viewer.liked {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(.red)
                            .accessibilityLabel(Text("Liked"))
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
