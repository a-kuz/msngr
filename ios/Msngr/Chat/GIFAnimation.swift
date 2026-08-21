import ImageIO
import UIKit

/// Plays an animated GIF into an image view, frame by frame, at the delays the
/// file itself carries. ImageIO decodes one frame at a time, so a long GIF costs
/// one frame of memory rather than all of them; `UIImage.animatedImage` would
/// hold every frame decoded at once and drops the per-frame delays.
final class GIFAnimation {
    private let source: CGImageSource?
    private let frameCount: Int
    private weak var view: UIImageView?
    private var timer: Timer?
    private var index = 0
    private var paused = false

    init(data: Data, into view: UIImageView) {
        source = CGImageSourceCreateWithData(data as CFData, nil)
        frameCount = source.map { CGImageSourceGetCount($0) } ?? 0
        self.view = view
    }

    /// Shows the first frame and walks the rest on a timer. A file with a single
    /// frame is a still image and stays one.
    func start() {
        guard frameCount > 0 else { return }
        show(0)
        guard frameCount > 1 else { return }
        schedule()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Off-screen the loop stands still: the frame on the tile stays, and the
    /// next tick resumes from it.
    func setPaused(_ value: Bool) {
        paused = value
    }

    private func schedule() {
        let interval = delay(at: index)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            guard self.view != nil else {
                self.stop()
                return
            }
            if !self.paused {
                self.index = (self.index + 1) % self.frameCount
                self.show(self.index)
            }
            self.schedule()
        }
    }

    private func show(_ frame: Int) {
        guard let source, let cg = CGImageSourceCreateImageAtIndex(source, frame, nil) else { return }
        view?.image = UIImage(cgImage: cg)
    }

    /// The delay written next to the frame. Browsers floor anything under 20 ms
    /// at 100 ms, and a GIF made for them looks wrong without the same floor.
    private func delay(at frame: Int) -> TimeInterval {
        guard let source,
              let props = CGImageSourceCopyPropertiesAtIndex(source, frame, nil) as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return 0.1 }
        let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double
        let value = unclamped ?? clamped ?? 0.1
        return value < 0.02 ? 0.1 : value
    }
}
