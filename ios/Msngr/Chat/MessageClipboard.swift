import UIKit
import MsngrCore

/// Буфер обмена для сообщений: копирование текста/фото и чтение вставленных картинок.
@MainActor
enum MessageClipboard {
    /// «Копировать» из контекстного меню: фото и альбом кладутся картинками,
    /// остальное — текстом.
    static func copy(_ msg: Message) {
        let photos = (msg.album ?? msg.media.map { [$0] } ?? []).filter { $0.type == "photo" }
        guard !photos.isEmpty, let mm = AppState.shared.media else {
            UIPasteboard.general.string = msg.text ?? ""
            return
        }
        Task {
            var images: [UIImage] = []
            for media in photos {
                guard let url = try? await mm.fetch(media),
                      let data = try? Data(contentsOf: url),
                      let image = UIImage(data: data) else { continue }
                images.append(image)
            }
            guard !images.isEmpty else { return }
            UIPasteboard.general.images = images
        }
    }

    /// Картинки из буфера; пусто, если там их нет.
    static func pastedImages() -> [UIImage] {
        guard UIPasteboard.general.hasImages else { return [] }
        return UIPasteboard.general.images ?? []
    }

    static var hasImages: Bool { UIPasteboard.general.hasImages }
}
