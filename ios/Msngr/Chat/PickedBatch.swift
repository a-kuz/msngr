import Foundation
import MsngrCore

/// What one pick from the photo library becomes: the message kind and the
/// placeholder per slot, typed as the item it will fill in to, so the row can
/// appear before a single byte of the selection has loaded.
enum PickedBatch {
    enum Item { case photo, video }

    static func kind(of items: [Item]) -> MessageKind {
        if items.count > 1 { return .album }
        return items.first == .video ? .video : .photo
    }

    static func blanks(for items: [Item]) -> [MediaInfo] {
        items.map { $0 == .video ? blankVideo() : blankPhoto() }
    }

    static func blankPhoto() -> MediaInfo {
        MediaInfo(type: "photo", mediaId: "", key: "", hash: "", size: 0, mime: "image/jpeg")
    }

    static func blankVideo() -> MediaInfo {
        MediaInfo(type: "video", mediaId: "", key: "", hash: "", size: 0, mime: "video/mp4")
    }
}
