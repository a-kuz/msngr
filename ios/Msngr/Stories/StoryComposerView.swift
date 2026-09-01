import SwiftUI
import PhotosUI
import MsngrCore

/// Composing a story: several pictures and videos in the order they were
/// picked, text over each of them, and the two things that decide its life —
/// who sees it and how long it lives.
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
    @State private var audience = "contacts"
    @State private var hours = 24
    @State private var wantsLink = false
    @State private var posting = false
    @State private var failed = false
    /// The frame whose text is being written, and the one open in the editor.
    @State private var editingText: Frame.ID?
    @State private var editingImage: Frame.ID?

    struct Frame: Identifiable, Equatable {
        let id = UUID()
        var image: UIImage
        var data: Data
        var isVideo: Bool
        var videoData: Data?
        var text: String = ""
        var textColor: String = "#ffffff"
        var plateColor: String = "rgba(0,0,0,.35)"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PhotosPicker(selection: $picked, maxSelectionCount: 10,
                                 selectionBehavior: .ordered, matching: .any(of: [.images, .videos])) {
                        Label(frames.isEmpty ? "Pick photos and videos" : "Pick more",
                              systemImage: "photo.on.rectangle.angled")
                    }
                    .accessibilityIdentifier("story.pick")
                } footer: {
                    Text("They go into the story in the order they were picked.")
                }

                if !frames.isEmpty {
                    Section("Frames") {
                        ForEach($frames) { $frame in
                            frameRow($frame)
                        }
                        .onDelete { frames.remove(atOffsets: $0) }
                        .onMove { frames.move(fromOffsets: $0, toOffset: $1) }
                    }
                }

                Section {
                    Picker("Who sees it", selection: $audience) {
                        Text("My contacts").tag("contacts")
                        Text("Everyone").tag("everyone")
                    }
                    .accessibilityIdentifier("story.audience")
                    Picker("How long it lives", selection: $hours) {
                        Text("6 hours").tag(6)
                        Text("A day").tag(24)
                        Text("A week").tag(168)
                    }
                    .accessibilityIdentifier("story.hours")
                    Toggle("A link anyone can open", isOn: $wantsLink)
                        .accessibilityIdentifier("story.link")
                } footer: {
                    Text(wantsLink
                         ? "A story is not encrypted: who sees it is a rule on the server, not a key. With a link it opens in any browser, with no app and no account."
                         : "A story is not encrypted: who sees it is a rule on the server, not a key.")
                }

                if failed {
                    Text("Not published").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New story")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Publish") { Task { await publish() } }
                        .disabled(frames.isEmpty || posting)
                        .accessibilityIdentifier("story.publish")
                }
            }
            .onChange(of: picked) { _, items in
                Task { await load(items) }
            }
            .sheet(item: Binding(get: { editingImage.map(IdentifiedID.init) },
                                 set: { editingImage = $0?.id })) { wrapper in
                if let index = frames.firstIndex(where: { $0.id == wrapper.id }) {
                    MarkupEditorScreen(image: frames[index].image) { edited in
                        if let jpeg = edited.jpegData(compressionQuality: 0.85) {
                            frames[index].image = edited
                            frames[index].data = jpeg
                        }
                        editingImage = nil
                    } onCancel: {
                        editingImage = nil
                    }
                    .ignoresSafeArea()
                }
            }
        }
    }

    private struct IdentifiedID: Identifiable { let id: UUID }

    @ViewBuilder
    private func frameRow(_ frame: Binding<Frame>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(uiImage: frame.wrappedValue.image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 54, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Text over the frame", text: frame.text)
                        .accessibilityIdentifier("story.frameText")
                    HStack(spacing: 10) {
                        ForEach(Self.textColors, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 20, height: 20)
                                .overlay {
                                    Circle().stroke(Color.primary.opacity(
                                        frame.wrappedValue.textColor == hex ? 0.9 : 0.15), lineWidth: 2)
                                }
                                .onTapGesture { frame.wrappedValue.textColor = hex }
                        }
                        Spacer()
                        // the same tools a picture gets before it is sent, so
                        // there is one set and not two
                        if !frame.wrappedValue.isVideo {
                            Button {
                                editingImage = frame.wrappedValue.id
                            } label: {
                                Image(systemName: "pencil.tip.crop.circle")
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("story.edit")
                        }
                    }
                }
            }
            Picker("", selection: frame.plateColor) {
                Text("Dark plate").tag("rgba(0,0,0,.35)")
                Text("Light plate").tag("rgba(255,255,255,.35)")
                Text("No plate").tag("rgba(0,0,0,0)")
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("story.plate")
        }
    }

    private static let textColors = ["#ffffff", "#ffd60a", "#ff453a", "#30d158", "#0a84ff"]

    private func load(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            if let prepared = ImageProcessor.prepareForSending(data, maxDimension: 1280),
               let image = UIImage(data: prepared.data) {
                frames.append(Frame(image: image, data: prepared.data, isVideo: false))
            }
        }
        picked = []
    }

    private func publish() async {
        posting = true
        defer { posting = false }
        var built: [APIClient.StoryFrame] = []
        for frame in frames {
            guard let uploaded = try? await app.api.uploadMedia(frame.data) else {
                failed = true
                return
            }
            built.append(APIClient.StoryFrame(
                mediaId: uploaded.mediaId, type: frame.isVideo ? "video" : "photo",
                w: Int(frame.image.size.width), h: Int(frame.image.size.height),
                text: frame.text.isEmpty ? nil : frame.text,
                textColor: frame.text.isEmpty ? nil : frame.textColor,
                plateColor: frame.text.isEmpty ? nil : frame.plateColor))
        }
        guard let posted = try? await app.api.postStory(frames: built, audience: audience,
                                                        hours: hours, link: wantsLink) else {
            failed = true
            return
        }
        await StoriesModel.shared.load()
        onPosted(posted.link)
        dismiss()
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
