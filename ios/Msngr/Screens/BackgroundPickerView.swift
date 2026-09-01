import SwiftUI
import PhotosUI
import MsngrCore

/// Picking a feed background: the gallery set, a picture of the user's own,
/// or none. Opened from a chat's card it sets that chat's background; opened
/// from the settings it sets the one every chat without its own uses.
struct BackgroundPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var surfaces = ShaderSurfaces.shared

    /// nil sets the background of every chat
    let chatId: String?

    @State private var photoItem: PhotosPickerItem?

    private var key: String { chatId ?? ShaderSurfaces.globalBackgroundKey }
    private var current: FeedBackground? { surfaces.feedBackgrounds[key] }

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    noneCard
                    ForEach(ShaderGallery.backgrounds, id: \.contentHash) { doc in
                        shaderCard(doc)
                    }
                    photoCard
                }
                .padding()
            }
            .navigationTitle(String(localized: "Background"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data),
                       let jpeg = image.jpegData(compressionQuality: 0.85),
                       let bg = surfaces.storeBackgroundImage(jpeg) {
                        surfaces.setFeedBackground(bg, for: chatId)
                        Haptics.success()
                    }
                    photoItem = nil
                }
            }
        }
    }

    private var noneCard: some View {
        Button {
            surfaces.setFeedBackground(nil, for: chatId)
        } label: {
            card(selected: current == nil) {
                ZStack {
                    Theme.chatBackground
                    Text("None").foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("background.none")
    }

    private func shaderCard(_ doc: ShaderDocument) -> some View {
        Button {
            surfaces.setFeedBackground(.shader(doc), for: chatId)
        } label: {
            card(selected: current == .shader(doc)) {
                ZStack(alignment: .bottomLeading) {
                    ShaderCanvasView(document: doc, running: true, deviceInputs: true, priority: .background)
                    Text(doc.name ?? String(localized: "Shader"))
                        .font(.caption)
                        .padding(6)
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("background.shader.\(doc.name ?? "")")
    }

    private var photoCard: some View {
        PhotosPicker(selection: $photoItem, matching: .images) {
            card(selected: { if case .image = current { return true } else { return false } }()) {
                ZStack {
                    if case .image(let name) = current,
                       let img = UIImage(contentsOfFile: ShaderSurfaces.imagesDir.appendingPathComponent(name).path) {
                        // fill the card without letting the picture dictate the cell's layout
                        Color.clear.overlay(Image(uiImage: img).resizable().scaledToFill())
                    } else {
                        Theme.chatBackground
                        VStack(spacing: 6) {
                            Image(systemName: "photo.badge.plus").font(.title2)
                            Text("Your photo").font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("background.photo")
    }

    private func card<Content: View>(selected: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(height: 160)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.2),
                                  lineWidth: selected ? 2.5 : 1)
            )
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .background(Circle().fill(.background))
                        .padding(6)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
