import SwiftUI
import AVKit
import MsngrCore

/// Фуллскрин-просмотрщик фото/видео: зум, свайп-вниз для закрытия, пейджинг альбома.
struct MediaViewerView: View {
    let message: Message
    let startIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var dragOffset: CGSize = .zero

    init(message: Message, startIndex: Int) {
        self.message = message
        self.startIndex = startIndex
        _index = State(initialValue: startIndex)
    }

    private var medias: [MediaInfo] {
        message.album ?? (message.media.map { [$0] } ?? [])
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - Double(abs(dragOffset.height)) / 500)
                .ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(medias.enumerated()), id: \.offset) { i, media in
                    MediaPage(media: media)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: medias.count > 1 ? .automatic : .never))
            .offset(dragOffset)
            .scaleEffect(1 - abs(dragOffset.height) / 1500)
            .gesture(
                DragGesture()
                    .onChanged { v in
                        if abs(v.translation.height) > abs(v.translation.width) {
                            dragOffset = v.translation
                        }
                    }
                    .onEnded { v in
                        if abs(v.translation.height) > 120 {
                            dismiss()
                        } else {
                            withAnimation(Theme.springFast) { dragOffset = .zero }
                        }
                    }
            )

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.4), in: Circle())
                    }
                    Spacer()
                    if let url = cachedURL {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(.black.opacity(0.4), in: Circle())
                        }
                    }
                }
                .padding()
                Spacer()
            }
            .opacity(dragOffset == .zero ? 1 : 0)
        }
        .statusBarHidden()
    }

    private var cachedURL: URL? {
        guard index < medias.count else { return nil }
        return AppState.shared.media?.cachedURL(for: medias[index].mediaId)
    }
}

private struct MediaPage: View {
    let media: MediaInfo
    @State private var localURL: URL?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        Group {
            if media.type == "video" {
                if let url = localURL {
                    VideoPlayerPage(url: url)
                } else {
                    ProgressView().tint(.white)
                }
            } else if let url = localURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                            .scaleEffect(scale)
                            .gesture(
                                MagnificationGesture()
                                    .onChanged { v in scale = max(1, lastScale * v) }
                                    .onEnded { _ in
                                        lastScale = scale
                                        if scale < 1.05 {
                                            withAnimation(Theme.springFast) { scale = 1; lastScale = 1 }
                                        }
                                    }
                            )
                            .onTapGesture(count: 2) {
                                withAnimation(Theme.springFast) {
                                    scale = scale > 1 ? 1 : 2.5
                                    lastScale = scale
                                }
                            }
                    } else {
                        blurPlaceholder
                    }
                }
            } else {
                blurPlaceholder
            }
        }
        .task {
            localURL = try? await AppState.shared.media?.fetch(media)
        }
    }

    private var blurPlaceholder: some View {
        Group {
            if let bh = media.blurhash,
               let px = BlurHash.decodePixels(bh, width: 32, height: 32),
               let img = UIImage.fromRGBA(px, width: 32, height: 32) {
                Image(uiImage: img).resizable().scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        }
    }
}

/// Видео: стриминг с range-запросов, потом локальный файл когда скачан.
private struct VideoPlayerPage: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear {
                player = AVPlayer(url: url)
                player?.play()
            }
            .onDisappear { player?.pause() }
    }
}
