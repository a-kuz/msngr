import SwiftUI
import MsngrCore

/// The sticker pack: every shader saved as a sticker, live in a grid. A tap
/// sends one; the plus opens the composer for a new one; a long press
/// removes one from the pack.
struct StickerPanelSheet: View {
    let onSend: (ShaderDocument) -> Void
    @ObservedObject private var surfaces = ShaderSurfaces.shared
    @State private var composing = false
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 10)]

    var body: some View {
        NavigationStack {
            Group {
                if surfaces.stickers.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "sparkles.rectangle.stack").font(Theme.glyph(40, max: 52)).foregroundStyle(.secondary)
                        Text("No stickers yet. Write one from Shadertoy code, or add one a friend sent.")
                            .font(Theme.Text.caption.font)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button { composing = true } label: { Label("New sticker", systemImage: "plus") }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(surfaces.stickers, id: \.contentHash) { doc in
                                StickerTile(document: doc)
                                    .onTapGesture {
                                        onSend(doc)
                                        dismiss()
                                    }
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            surfaces.removeSticker(doc)
                                        } label: {
                                            Label("Remove from stickers", systemImage: "trash")
                                        }
                                    }
                                    .accessibilityIdentifier("sticker.tile")
                            }
                        }
                        .padding(12)
                    }
                }
            }
            .navigationTitle(String(localized: "Stickers"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { composing = true } label: { Image(systemName: "plus") }
                        .accessibilityIdentifier("sticker.new")
                }
            }
            .sheet(isPresented: $composing) {
                ShaderComposerScreen(purpose: .sticker) { doc in
                    surfaces.addSticker(doc)
                }
            }
        }
        .onAppear { surfaces.load() }
    }
}

/// One sticker in the grid: live while the budget allows, a held frame otherwise.
struct StickerTile: View {
    let document: ShaderDocument

    var body: some View {
        ShaderCanvasView(document: document, running: true, transparent: true, priority: .avatar)
            .aspectRatio(1, contentMode: .fit)
            .background(Checkerboard().foregroundStyle(.secondary.opacity(0.15)))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                if let name = document.name {
                    Text(name).font(Theme.Text.caption.font).lineLimit(1)
                        .padding(4).background(.thinMaterial, in: Capsule()).padding(4)
                }
            }
    }
}
