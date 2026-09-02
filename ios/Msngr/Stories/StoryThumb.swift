import UIKit
import AVFoundation
import MsngrCore

/// The small picture of a story's frame: what a reply's strip shows in the
/// chat. A story's bytes were never encrypted, so the frame comes back as it
/// lies; a clip gives up its first frame.
enum StoryThumb {
    @MainActor
    static func load(_ story: StoryRef, pixelHeight: CGFloat) async -> UIImage? {
        guard let media = AppState.shared.media else { return nil }
        let isVideo = story.type == "video"
        guard let url = try? await media.fetchPlain(mediaId: story.mediaId,
                                                    mime: isVideo ? "video/mp4" : "image/jpeg")
        else { return nil }
        if isVideo {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: pixelHeight, height: pixelHeight)
            guard let (cg, _) = try? await gen.image(at: .zero) else { return nil }
            return UIImage(cgImage: cg)
        }
        let target = CGSize(width: pixelHeight, height: pixelHeight)
        guard let cg = await ImagePipeline.shared.image(at: url, targetPixelSize: target) else { return nil }
        return UIImage(cgImage: cg)
    }
}
