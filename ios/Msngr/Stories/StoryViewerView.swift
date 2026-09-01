import SwiftUI
import MsngrCore

/// Watching one author's stories. A tap on the right half moves on, a tap on
/// the left goes back, and a finger held anywhere stops the clock until it is
/// lifted. The frame fills the screen; the text the author laid over it sits on
/// its plate.
struct StoryViewerView: View {
    let author: StoriesModel.Author
    var onFinished: () -> Void

    @EnvironmentObject var app: AppState
    @ObservedObject private var model = StoriesModel.shared
    @Environment(\.dismiss) private var dismiss

    @State private var index = 0
    @State private var progress: Double = 0
    @State private var held = false
    @State private var frameURL: URL?
    @State private var reply = ""
    @State private var showViewers = false
    @State private var link: String?
    @State private var linkCopied = false

    /// How long one frame stands before the next one comes up.
    private static let frameSeconds: Double = 5
    private let tick = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    /// Every frame this author has live, in order: a story holds several, and
    /// the viewer walks them one after another without a seam between stories.
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
            Color.black.ignoresSafeArea()
            if let frameURL, let image = UIImage(contentsOfFile: frameURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
                    .accessibilityIdentifier("story.frame")
            } else {
                ProgressView().tint(.white)
            }
            if let text = slide?.frame.text, !text.isEmpty {
                VStack {
                    Spacer()
                    Text(text)
                        .font(.title3)
                        .foregroundStyle(Color(hex: slide?.frame.textColor ?? "#ffffff"))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.bottom, 120)
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
        .statusBarHidden()
        .task(id: index) { await showFrame() }
        .onReceive(tick) { _ in advanceClock() }
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
        // as it is wanted
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in held = true }
                .onEnded { _ in held = false }
        )
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
            if isMine, let story {
                Menu {
                    Button {
                        showViewers = true
                    } label: {
                        Label("Who watched", systemImage: "eye")
                    }
                    if let live = link ?? story.link {
                        Button {
                            UIPasteboard.general.string = live
                            linkCopied = true
                        } label: {
                            Label(linkCopied ? "Copied!" : "Copy link", systemImage: "link")
                        }
                        Button(role: .destructive) {
                            Task { link = try? await app.api.setStoryLink(story.id, open: false) }
                        } label: {
                            Label("Revoke the link", systemImage: "link.badge.plus")
                        }
                    } else {
                        Button {
                            Task { link = try? await app.api.setStoryLink(story.id, open: true) }
                        } label: {
                            Label("Make a link", systemImage: "link")
                        }
                    }
                    Button(role: .destructive) {
                        Task {
                            await model.takeDown(story.id)
                            onFinished()
                        }
                    } label: {
                        Label("Take it down", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(.white)
                }
                .accessibilityIdentifier("story.menu")
            }
            Button { onFinished() } label: {
                Image(systemName: "xmark").foregroundStyle(.white)
            }
            .accessibilityIdentifier("story.close")
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .sheet(isPresented: $showViewers) {
            if let story { StoryViewersSheet(storyId: story.id) }
        }
    }

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

    private func advanceClock() {
        guard !held, story != nil, frameURL != nil else { return }
        progress += 0.05 / Self.frameSeconds
        if progress >= 1 { step(1) }
    }

    private func step(_ delta: Int) {
        let next = index + delta
        guard next >= 0 else { return }
        guard next < slides.count else {
            onFinished()
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
        frameURL = try? await media.fetchPlain(mediaId: slide.frame.mediaId, mime: "image/jpeg")
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

enum StoryTime {
    /// How long ago, in the units a story lives by.
    static func ago(_ millis: Double, now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince1970 - millis / 1000
        if elapsed < 60 { return String(localized: "just now") }
        if elapsed < 3600 { return String(localized: "\(Int(elapsed / 60)) min ago") }
        return String(localized: "\(Int(elapsed / 3600)) h ago")
    }
}
