import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers
import MsngrCore

/// Composing a story the way every story editor works: the picked frame fills
/// the screen, the tools lie over it, the text is typed and dragged straight
/// onto the picture, and the frames the story is made of run as a filmstrip
/// along the bottom. The picker opens by itself when the screen comes up empty.
///
/// The screen says plainly what a story costs before it goes out: a story is
/// not encrypted, and who may see it is an access rule the server keeps rather
/// than a key only the audience holds.
struct StoryComposerView: View {
    var onPosted: (String?) -> Void
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var picked: [PhotosPickerItem] = []
    @State private var frames: [Frame] = []
    @State private var current = 0
    @State private var importing = 0
    @State private var audience = "contacts"
    @State private var hours = 24
    @State private var wantsLink = false
    @State private var posting = false
    @State private var failed = false
    @State private var showPicker = false
    @State private var showCamera = false
    @State private var markup = false
    /// The text tool is open: the keyboard is up and the words go onto the frame.
    @State private var typing = false
    @FocusState private var textFocused: Bool
    /// Where the text was before the finger moved it, so the drag adds to it.
    @State private var dragStart: CGPoint?

    struct Frame: Identifiable, Equatable {
        let id = UUID()
        var image: UIImage
        var data: Data
        var isVideo: Bool
        var duration: Double?
        var text: String = ""
        var textColor: String = "#ffffff"
        var plate: Plate = .dark
        /// The text's centre, as a fraction of the frame's width and height.
        var tx: Double = 0.5
        var ty: Double = 0.5
    }

    /// The plate behind the text, in the units the public page draws it in.
    enum Plate: String, CaseIterable {
        case dark = "rgba(0,0,0,.35)"
        case light = "rgba(255,255,255,.35)"
        case none = "rgba(0,0,0,0)"

        var next: Plate {
            switch self {
            case .dark: return .light
            case .light: return .none
            case .none: return .dark
            }
        }
        var color: Color {
            switch self {
            case .dark: return .black.opacity(0.35)
            case .light: return .white.opacity(0.35)
            case .none: return .clear
            }
        }
    }

    private static let textColors = ["#ffffff", "#000000", "#ffd60a", "#ff453a", "#30d158", "#0a84ff", "#bf5af2"]
    /// The simulator answers yes to the source and then has no device behind
    /// it, so both are asked before the button is drawn.
    private static let cameraAvailable = UIImagePickerController.isSourceTypeAvailable(.camera)
        && AVCaptureDevice.default(for: .video) != nil
        && (UIImagePickerController.availableMediaTypes(for: .camera) ?? []).contains(UTType.movie.identifier)

    private var frame: Frame? { current < frames.count ? frames[current] : nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if frames.isEmpty {
                emptyState
            } else {
                canvas
            }
            VStack(spacing: 0) {
                topBar
                Spacer()
                if !frames.isEmpty && !typing { bottomBar }
            }
        }
        .statusBarHidden()
        .photosPicker(isPresented: $showPicker, selection: $picked, maxSelectionCount: 10,
                      selectionBehavior: .ordered, matching: .any(of: [.images, .videos]))
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            Task { await load(items) }
        }
        .onAppear {
            // the screen comes up straight into the library, the way a story
            // starts everywhere: there is nothing to do here before a frame is in
            if frames.isEmpty { showPicker = true }
        }
        .fullScreenCover(isPresented: $markup) {
            if let frame {
                MarkupEditorScreen(image: frame.image) { edited in
                    if let jpeg = edited.jpegData(compressionQuality: 0.85) {
                        frames[current].image = edited
                        frames[current].data = jpeg
                    }
                    markup = false
                } onCancel: {
                    markup = false
                }
                .ignoresSafeArea()
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            StoryCamera { url in
                showCamera = false
                guard let url else { return }
                Task { await addVideo(at: url) }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - The frame

    private var canvas: some View {
        GeometryReader { geo in
            ZStack {
                if let frame {
                    // a frame that does not fill the screen stands over its
                    // own blurred copy rather than over black bars
                    Image(uiImage: frame.image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .blur(radius: 40)
                        .opacity(0.7)
                        .accessibilityHidden(true)
                    Image(uiImage: frame.image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .accessibilityIdentifier("story.canvas")
                    if frame.isVideo {
                        Image(systemName: "play.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.white.opacity(0.8))
                            .shadow(radius: 8)
                            .accessibilityHidden(true)
                    }
                    if typing {
                        Color.black.opacity(0.4)
                            .onTapGesture { finishTyping() }
                        typingField(in: geo.size)
                    } else if !frame.text.isEmpty {
                        textLabel(frame)
                            .position(x: frame.tx * geo.size.width, y: frame.ty * geo.size.height)
                            .gesture(dragText(in: geo.size))
                            .onTapGesture { typing = true; textFocused = true }
                    }
                }
            }
            // a swipe over the frame walks the filmstrip, the way it does in a viewer
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 40)
                    .onEnded { value in
                        guard !typing, abs(value.translation.width) > abs(value.translation.height) else { return }
                        let next = current + (value.translation.width < 0 ? 1 : -1)
                        if frames.indices.contains(next) { withAnimation { current = next } }
                    }
            )
        }
        .ignoresSafeArea()
    }

    private func textLabel(_ frame: Frame) -> some View {
        Text(frame.text)
            .font(.title2.weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(Color(hex: frame.textColor))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(frame.plate.color, in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: 320)
            .accessibilityIdentifier("story.text")
    }

    private func dragText(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard frame != nil else { return }
                if dragStart == nil {
                    dragStart = CGPoint(x: frames[current].tx, y: frames[current].ty)
                }
                let start = dragStart ?? CGPoint(x: 0.5, y: 0.5)
                frames[current].tx = min(max(start.x + value.translation.width / size.width, 0.08), 0.92)
                frames[current].ty = min(max(start.y + value.translation.height / size.height, 0.08), 0.92)
            }
            .onEnded { _ in dragStart = nil }
    }

    /// The text tool: the words are typed straight onto the frame, with the
    /// colour and the plate one tap away above the keyboard.
    private func typingField(in size: CGSize) -> some View {
        VStack {
            Spacer()
            TextField("", text: Binding(
                get: { frame?.text ?? "" },
                set: { if frame != nil { frames[current].text = $0 } }
            ), prompt: Text("Type something…").foregroundStyle(.white.opacity(0.5)),
               axis: .vertical)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color(hex: frame?.textColor ?? "#ffffff"))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background((frame?.plate ?? .dark).color, in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: 320)
                .focused($textFocused)
                .submitLabel(.done)
                .onSubmit { finishTyping() }
                .accessibilityIdentifier("story.textField")
            Spacer()
            HStack(spacing: 12) {
                Button {
                    if frame != nil { frames[current].plate = frames[current].plate.next }
                } label: {
                    Image(systemName: "character.textbox")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background((frame?.plate ?? .dark).color, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.6), lineWidth: 1))
                }
                .accessibilityIdentifier("story.plate")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Self.textColors, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 28, height: 28)
                                .overlay {
                                    Circle().stroke(.white, lineWidth: frame?.textColor == hex ? 3 : 1)
                                }
                                .onTapGesture { if frame != nil { frames[current].textColor = hex } }
                                .accessibilityIdentifier("story.color.\(hex.dropFirst())")
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .padding(.top, 60)
    }

    private func finishTyping() {
        textFocused = false
        typing = false
        if frame != nil {
            frames[current].text = frames[current].text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(alignment: .top) {
            Button {
                if typing { finishTyping() } else { dismiss() }
            } label: {
                Image(systemName: typing ? "checkmark" : "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .accessibilityIdentifier(typing ? "story.textDone" : "story.close")
            Spacer()
            if !frames.isEmpty && !typing {
                VStack(spacing: 14) {
                    tool("textformat", id: "story.addText") {
                        typing = true
                        textFocused = true
                    }
                    if frame?.isVideo == false {
                        // the same tools a picture gets before it is sent, so
                        // there is one set and not two
                        tool("pencil.tip.crop.circle", id: "story.edit") { markup = true }
                    }
                    if Self.cameraAvailable {
                        tool("camera", id: "story.camera") { showCamera = true }
                    }
                    tool("trash", id: "story.removeFrame") { removeCurrent() }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    private func tool(_ symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.35), in: Circle())
        }
        .accessibilityIdentifier(id)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                chip(audience == "contacts" ? "My contacts" : "Everyone",
                     symbol: audience == "contacts" ? "person.2" : "globe", id: "story.audience") {
                    audience = audience == "contacts" ? "everyone" : "contacts"
                }
                chip(hoursText, symbol: "clock", id: "story.hours") {
                    hours = hours == 6 ? 24 : hours == 24 ? 168 : 6
                }
                chip("Link", symbol: wantsLink ? "link" : "link.badge.plus", id: "story.link",
                     on: wantsLink) { wantsLink.toggle() }
                Spacer()
            }
            Text(wantsLink
                 ? "Not encrypted: who sees it is a rule on the server. With a link it opens in any browser."
                 : "Not encrypted: who sees it is a rule on the server, not a key.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("story.plainNote")
            HStack(spacing: 12) {
                filmstrip
                Button {
                    Task { await publish() }
                } label: {
                    ZStack {
                        Circle().fill(Theme.accent)
                        if posting {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "arrow.right")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 52, height: 52)
                }
                .disabled(posting || importing > 0)
                .accessibilityIdentifier("story.publish")
            }
            if failed {
                Text("Not published")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .accessibilityIdentifier("story.failed")
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 20)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .padding(.top, -60)
                .ignoresSafeArea()
        )
    }

    private var hoursText: LocalizedStringResource {
        switch hours {
        case 6: return "6 hours"
        case 168: return "A week"
        default: return "A day"
        }
    }

    private func chip(_ title: LocalizedStringResource, symbol: String, id: String,
                      on: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(String(localized: title), systemImage: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(on ? .white : .white.opacity(0.6))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.white.opacity(on ? 0.22 : 0.1), in: Capsule())
        }
        .accessibilityIdentifier(id)
    }

    /// The frames the story is made of, in the order they go out: a tap
    /// selects one, and the last cell adds more.
    private var filmstrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(frames.enumerated()), id: \.element.id) { index, f in
                    Image(uiImage: f.image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 40, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(index == current ? Color.white : .clear, lineWidth: 2)
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if f.isVideo {
                                Image(systemName: "video.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.white)
                                    .padding(3)
                            }
                        }
                        .onTapGesture { withAnimation { current = index } }
                        .accessibilityIdentifier("story.frame.\(index)")
                }
                if importing > 0 {
                    ProgressView().tint(.white).frame(width: 40, height: 56)
                }
                Button { showPicker = true } label: {
                    Image(systemName: "plus")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 56)
                        .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .accessibilityIdentifier("story.pick")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            if importing > 0 {
                ProgressView().tint(.white)
            } else {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 52))
                    .foregroundStyle(.white.opacity(0.6))
                Button { showPicker = true } label: {
                    Text("Pick photos and videos")
                        .fontWeight(.semibold)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(.white, in: Capsule())
                }
                .accessibilityIdentifier("story.pick")
                if Self.cameraAvailable {
                    Button { showCamera = true } label: {
                        Label("Shoot a video", systemImage: "camera")
                            .foregroundStyle(.white)
                    }
                    .accessibilityIdentifier("story.camera")
                }
            }
            Spacer()
        }
    }

    // MARK: - Frames in and out

    private func removeCurrent() {
        guard frame != nil else { return }
        frames.remove(at: current)
        current = min(current, max(frames.count - 1, 0))
    }

    private func load(_ items: [PhotosPickerItem]) async {
        picked = []
        importing += items.count
        for item in items {
            defer { importing -= 1 }
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
            if isVideo {
                if let movie = try? await item.loadTransferable(type: VideoTransferable.self) {
                    await addVideo(at: movie.url)
                }
            } else if let data = try? await item.loadTransferable(type: Data.self),
                      let prepared = ImageProcessor.prepareForSending(data, maxDimension: 1280),
                      let image = UIImage(data: prepared.data) {
                append(Frame(image: image, data: prepared.data, isVideo: false))
            }
        }
    }

    /// A video goes out as a progressive mp4 with a poster taken from its first
    /// moment; the poster is what the composer and the filmstrip show.
    private func addVideo(at url: URL) async {
        defer { try? FileManager.default.removeItem(at: url) }
        guard let ready = await StoryVideo.prepare(url) else { return }
        append(Frame(image: ready.poster, data: ready.data, isVideo: true, duration: ready.duration))
    }

    private func append(_ frame: Frame) {
        frames.append(frame)
        current = frames.count - 1
    }

    private func publish() async {
        guard !frames.isEmpty else { return }
        posting = true
        failed = false
        defer { posting = false }
        var built: [APIClient.StoryFrame] = []
        for frame in frames {
            guard let uploaded = try? await app.api.uploadMedia(frame.data) else {
                failed = true
                return
            }
            let hasText = !frame.text.isEmpty
            built.append(APIClient.StoryFrame(
                mediaId: uploaded.mediaId, type: frame.isVideo ? "video" : "photo",
                w: Int(frame.image.size.width), h: Int(frame.image.size.height),
                dur: frame.duration,
                text: hasText ? frame.text : nil,
                textColor: hasText ? frame.textColor : nil,
                plateColor: hasText ? frame.plate.rawValue : nil,
                tx: hasText ? frame.tx : nil, ty: hasText ? frame.ty : nil))
        }
        guard let posted = try? await app.api.postStory(frames: built, audience: audience,
                                                        hours: hours, link: wantsLink) else {
            failed = true
            return
        }
        Haptics.success()
        await StoriesModel.shared.load()
        onPosted(posted.link)
        dismiss()
    }
}

/// A picked or shot video made ready for a story: compressed the way a chat
/// video is, with a poster frame and its length.
enum StoryVideo {
    struct Ready {
        let data: Data
        let poster: UIImage
        let duration: Double
    }

    static func prepare(_ url: URL) async -> Ready? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1280, height: 1280)
        guard let cg = try? gen.copyCGImage(at: .init(seconds: 0.1, preferredTimescale: 600), actualTime: nil)
        else { return nil }
        let poster = UIImage(cgImage: cg)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else {
            return nil
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("story-\(UUID().uuidString).mp4")
        export.outputURL = out
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        await export.export()
        defer { try? FileManager.default.removeItem(at: out) }
        guard export.status == .completed, let data = try? Data(contentsOf: out) else { return nil }
        return Ready(data: data, poster: poster, duration: duration)
    }
}

/// The system camera, set to shoot a clip: the story never leaves the composer
/// for it. Hands back the recording's file, or nil when nothing was shot.
struct StoryCamera: UIViewControllerRepresentable {
    let onDone: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.movie.identifier]
        picker.cameraCaptureMode = .video
        picker.videoQuality = .typeHigh
        picker.videoMaximumDuration = 60
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onDone: (URL?) -> Void
        init(onDone: @escaping (URL?) -> Void) { self.onDone = onDone }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onDone(info[.mediaURL] as? URL)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onDone(nil)
        }
    }
}

extension Color {
    /// "#rrggbb", the way a story frame carries its colour.
    init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt32(cleaned, radix: 16) ?? 0xffffff
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xff) / 255,
                  green: Double((value >> 8) & 0xff) / 255,
                  blue: Double(value & 0xff) / 255)
    }
}
