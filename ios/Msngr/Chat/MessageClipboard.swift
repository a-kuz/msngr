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

    /// Мультивыбор: строка на сообщение, в порядке переписки (сверху старое).
    /// Одно сообщение копируется обычным путём — фото попадает в буфер картинкой.
    static func copy(_ msgs: [Message]) {
        guard msgs.count != 1 else { return copy(msgs[0]) }
        guard !msgs.isEmpty else { return }
        UIPasteboard.general.string = msgs.reversed()
            .map { ($0.text?.isEmpty == false ? $0.text! : ChatViewModel.previewText($0)) }
            .joined(separator: "\n")
    }

    /// Картинки из буфера; пусто, если там их нет.
    static func pastedImages() -> [UIImage] {
        guard UIPasteboard.general.hasImages else { return [] }
        return UIPasteboard.general.images ?? []
    }

    static var hasImages: Bool { UIPasteboard.general.hasImages }
}
