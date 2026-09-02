import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers
import MsngrCore

/// Composing a story the way every story editor works: the screen opens on the
/// front camera with a shutter and the library a tap away; the shot or picked
/// frame then fills the screen and the tools lie over it. Text and emoji are
/// laid on as layers that move, pinch and turn under the fingers, strokes go
/// straight onto the picture or the clip, and every step is one undo away.
/// What leaves is the canvas as it stands, baked into the picture or burnt into
/// the clip, so the viewer and the public page show exactly what was composed.
///
/// The screen says plainly what a story costs before it goes out: a story is
/// not encrypted, and who may see it is an access rule the server keeps rather
/// than a key only the audience holds.
struct StoryComposerView: View {
    var onPosted: (String?) -> Void
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var picked: [PhotosPickerItem] = []
    @State private var frames: [StoryFrame] = []
    @State private var current = 0
    @State private var importing = 0
    @State private var audience = "contacts"
    @State private var hours = 24
    @State private var wantsLink = false
    @State private var posting = false
    @State private var failed = false
    @State private var showPicker = false
    /// The camera is up over a story that already has frames: another take.
    @State private var capturing = false
    @State private var tool: Tool = .arrange
    @State private var showStickers = false
    /// The story as it stood before each step, newest last; undo pops one.
    @State private var history: [Snapshot] = []
    @State private var canvasSize: CGSize = .zero
    /// A layer is being dragged, and whether it hangs over the bin.
    @State private var dragging = false
    @State private var overBin = false
    @State private var brush: StoryStroke.Brush = .pen
    @State private var brushColor = "#ffffff"
    /// As a fraction of the canvas width, the unit strokes are kept in.
    @State private var brushWidth: CGFloat = 0.012
    @FocusState private var textFocused: Bool
    /// The text tool has finished coming up: the field grows into place.
    @State private var editorShown = false

    enum Tool: Equatable {
        case arrange
        /// The text tool is open on this layer: the keyboard is up.
        case text(UUID)
        case draw
    }

    struct Snapshot: Equatable {
        var frames: [StoryFrame]
        var current: Int
    }

    static let colors = ["#ffffff", "#000000", "#ff3b30", "#ff9500", "#ffcc00", "#34c759",
                         "#00c7be", "#30b0ff", "#5856d6", "#af52de", "#ff2d55", "#a2845e",
                         "#8e8e93", "#ffd1dc", "#c7f9cc", "#b4e1ff"]
    private static let cameraAvailable = AVCaptureDevice.default(for: .video) != nil

    private var showingCamera: Bool { frames.isEmpty || capturing }
    private var frame: StoryFrame? { current < frames.count ? frames[current] : nil }
    private var editingLayer: UUID? {
        if case .text(let id) = tool { return id }
        return nil
    }
    private var editing: StoryLayer? {
        guard let id = editingLayer else { return nil }
        return frame?.layers.first { $0.id == id }
    }
    private var chromeHidden: Bool { editingLayer != nil || dragging }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if showingCamera {
                StoryCaptureView { image in
                    addPhoto(image)
                } onVideo: { url in
                    Task { await addVideo(at: url) }
                } onLibrary: {
                    showPicker = true
                }
            } else {
                canvas
            }
            if let editing {
                textEditor(editing)
                    .transition(.opacity)
                    .onAppear { withAnimation(.spring(duration: 0.35)) { editorShown = true } }
                    .onDisappear { editorShown = false }
            }
            VStack(spacing: 0) {
                topBar
                Spacer()
                if tool == .draw {
                    drawBar
                } else if !showingCamera && !chromeHidden {
                    bottomBar
                }
            }
            if dragging { bin }
        }
        .statusBarHidden()
        .photosPicker(isPresented: $showPicker, selection: $picked, maxSelectionCount: 10,
                      selectionBehavior: .ordered, matching: .any(of: [.images, .videos]))
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            Task { await load(items) }
        }
        .sheet(isPresented: $showStickers) {
            StoryStickerSheet { emoji in
                showStickers = false
                addSticker(emoji)
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(.thinMaterial)
        }
    }

    // MARK: - The canvas

    private var canvas: some View {
        GeometryReader { geo in
            if let frame {
                StoryCanvasView(
                    frame: frame,
                    mode: tool == .draw ? .draw(brush: brush, color: brushColor, width: brushWidth) : .arrange,
                    hiddenLayer: editingLayer,
                    paused: showStickers || posting,
                    onBegin: { remember() },
                    onCommit: { updated in
                        if current < frames.count { frames[current] = updated }
                    },
                    onTapLayer: { id in
                        guard tool == .arrange, let layer = frame.layers.first(where: { $0.id == id }) else { return }
                        if !layer.isEmoji { startTyping(id) }
                    },
                    onTapEmpty: { point in
                        guard tool == .arrange else { return }
                        addText(at: point)
                    },
                    onDragging: { active, near in
                        dragging = active
                        overBin = near
                    })
                .onAppear { canvasSize = geo.size }
                .onChange(of: geo.size) { _, size in canvasSize = size }
                .accessibilityIdentifier("story.canvas")
                // a swipe over the frame walks the filmstrip, the way it does in a viewer
                .simultaneousGesture(
                    DragGesture(minimumDistance: 60)
                        .onEnded { value in
                            guard tool == .arrange, !dragging,
                                  abs(value.translation.width) > abs(value.translation.height) * 2 else { return }
                            let next = current + (value.translation.width < 0 ? 1 : -1)
                            if frames.indices.contains(next) { withAnimation { current = next } }
                        }
                )
            }
        }
        .ignoresSafeArea()
    }

    /// Where a dragged layer is let go to be thrown away.
    private var bin: some View {
        VStack {
            Spacer()
            Image(systemName: "trash")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: StoryCanvas.binRadius * 2, height: StoryCanvas.binRadius * 2)
                .background(overBin ? Color.red : Color.black.opacity(0.45), in: Circle())
                .scaleEffect(overBin ? 1.15 : 1)
                .animation(.spring(duration: 0.2), value: overBin)
                .padding(.bottom, StoryCanvas.binBottomInset - StoryCanvas.binRadius)
        }
        .ignoresSafeArea()
        .transition(.scale.combined(with: .opacity))
        .accessibilityIdentifier("story.bin")
    }

    // MARK: - The text tool

    /// The words are typed straight onto the frame in the style they will
    /// keep, with the fonts, the alignment, the plate and the colours one tap
    /// away above the keyboard.
    private func textEditor(_ layer: StoryLayer) -> some View {
        let font = layer.font.uiFont(size: StoryRenderer.textBase * max(canvasSize.width, 1) * layer.scale)
        return ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { finishTyping() }
            let alignment: TextAlignment = layer.alignment == .left ? .leading
                : layer.alignment == .right ? .trailing : .center
            VStack(spacing: 0) {
                Spacer()
                // the plate hugs the words: an unseen copy of the text sets the
                // width, and the field fills it
                ZStack {
                    Text(layer.text.isEmpty ? String(localized: "Type something…") : layer.text)
                        .font(Font(font as CTFont))
                        .multilineTextAlignment(alignment)
                        .foregroundStyle(.white.opacity(layer.text.isEmpty ? 0.5 : 0))
                        .accessibilityHidden(true)
                    TextField("", text: Binding(
                        get: { editing?.text ?? "" },
                        set: { value in
                            // the keyboard's Done key lands as a newline in a
                            // growing field: it closes the tool instead
                            if value.hasSuffix("\n") {
                                editLayer { $0.kind = .text(String(value.dropLast())) }
                                finishTyping()
                            } else {
                                editLayer { $0.kind = .text(value) }
                            }
                        }
                    ), axis: .vertical)
                        .font(Font(font as CTFont))
                        .multilineTextAlignment(alignment)
                        .foregroundStyle(Color(hex: layer.color))
                        .focused($textFocused)
                        .submitLabel(.done)
                        .onSubmit { finishTyping() }
                        // the field is not in the hierarchy on the tick the tool
                        // opens, so it takes the focus when it arrives
                        .onAppear { textFocused = true }
                        .accessibilityIdentifier("story.textField")
                }
                .padding(.horizontal, font.pointSize * 0.42)
                .padding(.vertical, font.pointSize * 0.22)
                .background(layer.plate.uiColor.map { Color(uiColor: $0) } ?? .clear,
                            in: RoundedRectangle(cornerRadius: font.pointSize * 0.3, style: .continuous))
                .frame(maxWidth: canvasSize.width * 0.86 * layer.scale)
                .scaleEffect(editorShown ? 1 : 0.7)
                .opacity(editorShown ? 1 : 0)
                Spacer()
                textTools(layer)
                    .offset(y: editorShown ? 0 : 40)
                    .opacity(editorShown ? 1 : 0)
            }
        }
    }

    private func textTools(_ layer: StoryLayer) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    editLayer { $0.alignment = $0.alignment == .center ? .left : $0.alignment == .left ? .right : .center }
                } label: {
                    Image(systemName: layer.alignment == .left ? "text.alignleft"
                          : layer.alignment == .right ? "text.alignright" : "text.aligncenter")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityIdentifier("story.align")
                Button {
                    editLayer { $0.plate = $0.plate.next }
                } label: {
                    Image(systemName: "character.textbox")
                        .font(.title3)
                        .foregroundStyle(layer.plate == .light ? .black : .white)
                        .frame(width: 36, height: 36)
                        .background(layer.plate.uiColor.map { Color(uiColor: $0) } ?? .white.opacity(0.18),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.6), lineWidth: 1))
                }
                .accessibilityIdentifier("story.plate")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(StoryFont.allCases, id: \.self) { font in
                            Button {
                                editLayer { $0.font = font }
                            } label: {
                                Text(String(localized: String.LocalizationValue(font.name)))
                                    .font(Font(font.uiFont(size: 15) as CTFont))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(.white.opacity(layer.font == font ? 0.35 : 0.15), in: Capsule())
                            }
                            .accessibilityIdentifier("story.font.\(font.name)")
                        }
                    }
                }
            }
            palette(selected: layer.color) { hex in editLayer { $0.color = hex } }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private func palette(selected: String, pick: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Self.colors, id: \.self) { hex in
                    Button { pick(hex) } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 30, height: 30)
                            .overlay {
                                Circle().stroke(.white, lineWidth: selected == hex ? 3 : 1)
                            }
                            .scaleEffect(selected == hex ? 1.15 : 1)
                            .animation(.spring(duration: 0.2), value: selected == hex)
                    }
                    .accessibilityIdentifier("story.color.\(hex.dropFirst())")
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
    }

    /// Rewrites the layer under the text tool; the snapshot taken when the tool
    /// opened is what the undo step holds.
    private func editLayer(_ change: (inout StoryLayer) -> Void) {
        guard let id = editingLayer, current < frames.count,
              let i = frames[current].layers.firstIndex(where: { $0.id == id }) else { return }
        change(&frames[current].layers[i])
    }

    private func addText(at point: CGPoint) {
        guard current < frames.count else { return }
        remember()
        var layer = StoryLayer(kind: .text(""))
        layer.center = CGPoint(x: min(max(point.x, 0.15), 0.85), y: min(max(point.y, 0.15), 0.85))
        frames[current].layers.append(layer)
        withAnimation(.easeOut(duration: 0.2)) { tool = .text(layer.id) }
        textFocused = true
    }

    private func startTyping(_ id: UUID) {
        remember()
        withAnimation(.easeOut(duration: 0.2)) { tool = .text(id) }
        textFocused = true
    }

    private func finishTyping() {
        guard let id = editingLayer else { return }
        textFocused = false
        withAnimation(.easeOut(duration: 0.2)) { tool = .arrange }
        if current < frames.count, let i = frames[current].layers.firstIndex(where: { $0.id == id }) {
            let trimmed = frames[current].layers[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                frames[current].layers.remove(at: i)
            } else {
                frames[current].layers[i].kind = .text(trimmed)
            }
        }
        // a tool opened and closed with nothing changed is not a step
        if let last = history.last, last == Snapshot(frames: frames, current: current) {
            history.removeLast()
        }
    }

    private func addSticker(_ emoji: String) {
        guard current < frames.count else { return }
        remember()
        var layer = StoryLayer(kind: .emoji(emoji))
        // each new sticker lands a little off the last, so a run of them does
        // not stack into one
        let n = Double(frames[current].layers.filter(\.isEmoji).count)
        layer.center = CGPoint(x: 0.5 + (n.truncatingRemainder(dividingBy: 3) - 1) * 0.08,
                               y: 0.45 + (n / 3).rounded(.down).truncatingRemainder(dividingBy: 3) * 0.08)
        frames[current].layers.append(layer)
    }

    // MARK: - The drawing tool

    private var drawBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(StoryStroke.Brush.allCases, id: \.self) { b in
                    Button { brush = b } label: {
                        Image(systemName: b == .pen ? "pencil.tip" : b == .marker ? "highlighter" : "sparkles")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 36)
                            .background(.white.opacity(brush == b ? 0.35 : 0.15), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .accessibilityIdentifier("story.brush.\(b)")
                }
                Slider(value: Binding(get: { Double(brushWidth) }, set: { brushWidth = CGFloat($0) }),
                       in: 0.004...0.04)
                    .tint(.white)
                    .accessibilityIdentifier("story.brushWidth")
                Circle()
                    .fill(Color(hex: brushColor))
                    .frame(width: max(6, brushWidth * canvasSize.width * 1.5),
                           height: max(6, brushWidth * canvasSize.width * 1.5))
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.15), in: Circle())
            }
            palette(selected: brushColor) { brushColor = $0 }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                .padding(.top, -40)
                .ignoresSafeArea()
        )
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(alignment: .top) {
            Button {
                if editingLayer != nil {
                    finishTyping()
                } else if tool == .draw {
                    tool = .arrange
                } else if capturing && !frames.isEmpty {
                    capturing = false
                } else {
                    dismiss()
                }
            } label: {
                Image(systemName: editingLayer != nil || tool == .draw ? "checkmark" : "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .accessibilityIdentifier(editingLayer != nil ? "story.textDone" : tool == .draw ? "story.drawDone" : "story.close")
            Spacer()
            if !history.isEmpty && !showingCamera && !dragging {
                tool("arrow.uturn.backward", id: "story.undo") { undo() }
                    .padding(.trailing, 14)
            }
            if !showingCamera && !chromeHidden && tool != .draw {
                VStack(spacing: 14) {
                    tool("textformat", id: "story.addText") { addText(at: CGPoint(x: 0.5, y: 0.45)) }
                    tool("scribble.variable", id: "story.draw") { tool = .draw }
                    tool("face.smiling", id: "story.stickers") { showStickers = true }
                    if frame?.isVideo == true {
                        tool(frame?.muted == true ? "speaker.slash.fill" : "speaker.wave.2.fill", id: "story.mute") {
                            remember()
                            frames[current].muted.toggle()
                        }
                    }
                    if Self.cameraAvailable {
                        tool("camera", id: "story.camera") { capturing = true }
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

    // MARK: - Undo

    /// Keeps the story as it stands, to be brought back by the undo button.
    private func remember() {
        let now = Snapshot(frames: frames, current: current)
        if history.last != now { history.append(now) }
    }

    private func undo() {
        guard let previous = history.popLast() else { return }
        if editingLayer != nil { textFocused = false }
        tool = .arrange
        frames = previous.frames
        current = min(previous.current, max(frames.count - 1, 0))
        capturing = false
    }

    // MARK: - Frames in and out

    private func removeCurrent() {
        guard frame != nil else { return }
        remember()
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
                      let prepared = ImageProcessor.prepareForSending(data, maxDimension: 1600),
                      let image = UIImage(data: prepared.data) {
                append(StoryFrame(image: image, isVideo: false))
            }
        }
    }

    /// A picture from the camera, cut down the way a picked one is.
    private func addPhoto(_ image: UIImage) {
        guard let jpeg = image.jpegData(compressionQuality: 0.92),
              let prepared = ImageProcessor.prepareForSending(jpeg, maxDimension: 1600),
              let ready = UIImage(data: prepared.data) else { return }
        append(StoryFrame(image: ready, isVideo: false))
    }

    /// A clip stays on disk as it came until the story goes out: the overlay
    /// is burnt in once, at publish, over the whole of what was drawn.
    private func addVideo(at url: URL) async {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1280, height: 1280)
        guard let cg = try? await gen.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image else { return }
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        append(StoryFrame(image: UIImage(cgImage: cg), isVideo: true, videoURL: url, duration: min(duration, 60)))
    }

    private func append(_ frame: StoryFrame) {
        remember()
        frames.append(frame)
        current = frames.count - 1
        capturing = false
    }

    private func publish() async {
        guard !frames.isEmpty, canvasSize.width > 0 else { return }
        posting = true
        failed = false
        defer { posting = false }
        var built: [APIClient.StoryFrame] = []
        for frame in frames {
            let data: Data
            let size: CGSize
            var duration: Double?
            if frame.isVideo {
                guard let exported = await StoryRenderer.renderVideo(frame, canvas: canvasSize) else {
                    failed = true
                    return
                }
                data = exported.data
                size = exported.size
                duration = exported.duration
            } else {
                let rendered = StoryRenderer.renderPhoto(frame, canvas: canvasSize)
                guard let jpeg = rendered.jpegData(compressionQuality: 0.88) else {
                    failed = true
                    return
                }
                data = jpeg
                size = rendered.size
            }
            guard let uploaded = try? await app.api.uploadMedia(data) else {
                failed = true
                return
            }
            built.append(APIClient.StoryFrame(
                mediaId: uploaded.mediaId, type: frame.isVideo ? "video" : "photo",
                w: Int(size.width), h: Int(size.height), dur: duration))
        }
        guard let posted = try? await app.api.postStory(frames: built, audience: audience,
                                                        hours: hours, link: wantsLink) else {
            failed = true
            return
        }
        Haptics.success()
        for frame in frames { if let url = frame.videoURL { try? FileManager.default.removeItem(at: url) } }
        await StoriesModel.shared.load()
        onPosted(posted.link)
        dismiss()
    }
}

/// Emoji to lay on a frame as stickers, the common ones in a grid and the
/// keyboard's own set a search away.
struct StoryStickerSheet: View {
    let onPick: (String) -> Void
    @State private var typed = ""

    private static let emoji: [String] = Array(
        "😀😂🥹😍🥰😎🤩😘😜🤪🥳😇🙃😏😢😭😱🤯🥶🔥✨💫⭐️🌈☀️🌙⚡️❄️🎉🎈🎁🎂🍕🍔🍟🌮🍩🍦🍓🍒🍉🥑☕️🍺🥂❤️🧡💛💚💙💜🖤🤍💔💯👍👎👏🙌🤝🙏💪👀👋🤙✌️🤞🐶🐱🐭🐹🐰🦊🐻🐼🐨🐯🦁🐸🐵🦄🐙🦋🌸🌻🌹🌵🌴🍀🏀⚽️🎾🎮🎧🎸🎤📸💻📱✈️🚗🏠🌍🕶️👑💎💰🔑🔔💤💬"
    ).map(String.init)

    var body: some View {
        VStack(spacing: 12) {
            TextField("Search emoji", text: $typed)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .onChange(of: typed) { _, value in
                    // whatever emoji the keyboard produced is the sticker
                    guard value.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) else { return }
                    onPick(value)
                    typed = ""
                }
                .accessibilityIdentifier("story.stickerSearch")
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 14) {
                    ForEach(Self.emoji, id: \.self) { e in
                        Button { onPick(e) } label: {
                            Text(e).font(.system(size: 38))
                        }
                        .accessibilityIdentifier("story.sticker.\(e)")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 20)
            }
        }
    }
}

extension Color {
    /// "#rrggbb", the way a story layer carries its colour.
    init(hex: String) {
        self.init(UIColor(hex: hex))
    }
}
