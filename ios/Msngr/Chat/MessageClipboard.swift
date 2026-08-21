import UIKit
import MsngrCore

/// Clipboard for messages: copying text and photos, and reading pasted images back.
@MainActor
enum MessageClipboard {
    /// Copy from the context menu: a photo or an album goes in as images,
    /// everything else as text.
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

    /// Multi-select: one line per message, in conversation order with the oldest on top.
    /// A single message goes the usual way, so a photo lands on the clipboard as an image.
    static func copy(_ msgs: [Message]) {
        guard msgs.count != 1 else { return copy(msgs[0]) }
        guard !msgs.isEmpty else { return }
        UIPasteboard.general.string = bulkText(msgs)
    }

    /// What a bulk copy puts on the clipboard: the messages come in feed order
    /// (newest first) and leave oldest on top; a message with no text is
    /// represented by its preview line.
    static func bulkText(_ msgs: [Message]) -> String {
        msgs.reversed()
            .map { ($0.text?.isEmpty == false ? $0.text! : ChatViewModel.previewText($0)) }
            .joined(separator: "\n")
    }

    /// Images from the clipboard; empty when it holds none.
    static func pastedImages() -> [UIImage] {
        guard UIPasteboard.general.hasImages else { return [] }
        return UIPasteboard.general.images ?? []
    }

    static var hasImages: Bool { UIPasteboard.general.hasImages }
}
