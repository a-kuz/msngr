import Foundation
import CoreGraphics
import ImageIO

/// CGImage wrapper for NSCache, which only stores class types.
private final class ImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// Image pipeline: downsampling and forced decode off the main thread, with an in-memory cache.
/// On a memory warning the caller is expected to call clearMemory().
public final class ImagePipeline: @unchecked Sendable {
    public static let shared = ImagePipeline()

    private let cache = NSCache<NSString, ImageBox>()
    private let lock = NSLock()
    private var inflight: [String: Task<CGImage?, Never>] = [:]

    public init() {
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    /// Decodes the image off the main thread, downsampled to targetPixelSize (in pixels).
    /// The result is a CGImage ready to draw and is kept in the memory cache.
    public func image(at url: URL, targetPixelSize: CGSize) async -> CGImage? {
        let key = Self.key(url, targetPixelSize)
        if let boxed = cache.object(forKey: key as NSString) {
            return boxed.image
        }

        lock.lock()
        if let existing = inflight[key] {
            lock.unlock()
            return await existing.value
        }
        let task = Task<CGImage?, Never>(priority: .userInitiated) {
            Self.decode(url: url, targetPixelSize: targetPixelSize)
        }
        inflight[key] = task
        lock.unlock()

        let image = await task.value
        if let image {
            cache.setObject(ImageBox(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
        }
        lock.lock()
        inflight[key] = nil
        lock.unlock()
        return image
    }

    /// Synchronous hit from memory if the image is already decoded, so a reused cell
    /// can show it in the same frame.
    public func cachedImage(at url: URL, targetPixelSize: CGSize) -> CGImage? {
        cache.object(forKey: Self.key(url, targetPixelSize) as NSString)?.image
    }

    public func prefetch(urls: [(URL, CGSize)]) {
        for (url, size) in urls {
            Task(priority: .utility) { [weak self] in
                _ = await self?.image(at: url, targetPixelSize: size)
            }
        }
    }

    public func clearMemory() {
        cache.removeAllObjects()
    }

    private static func key(_ url: URL, _ targetPixelSize: CGSize) -> String {
        "\(url.path)|\(Int(max(targetPixelSize.width, targetPixelSize.height)))"
    }

    /// Downsampling through ImageIO: decodes straight to the reduced size without ever
    /// materialising the full frame. kCGImageSourceShouldCacheImmediately forces the decode
    /// here rather than during an offscreen render pass.
    private static func decode(url: URL, targetPixelSize: CGSize) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let maxPixel = max(targetPixelSize.width, targetPixelSize.height)
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
    }
}

/// Preparing images for sending, plus the conversions that go with it.
public enum ImageProcessor {
    /// Downscale and re-encode as JPEG for sending: long side capped at maxDimension,
    /// quality 0.8. Returns the JPEG data and the pixel size. Input may be any format
    /// ImageIO can read.
    public static func prepareForSending(_ data: Data, maxDimension: CGFloat = 1280) -> (data: Data, size: CGSize)? {
        guard let image = downsample(data, maxDimension: maxDimension) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
        let properties = [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, CGSize(width: image.width, height: image.height))
    }

    /// True when the data is a GIF holding more than one frame. Such a file is sent
    /// as it came: the JPEG pass below keeps a single frame and the animation is
    /// what the sender meant to send.
    public static func isAnimatedGIF(_ data: Data) -> Bool {
        guard data.count > 6, data.starts(with: Array("GIF8".utf8)) else { return false }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    /// The pixel size of the first frame, for a file that travels unchanged.
    public static func pixelSize(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: width, height: height)
    }

    /// RGBA8 pixels of a shrunken copy with a long side of about 32px, for BlurHash encoding.
    public static func rgbaPixels(_ data: Data, maxDimension: CGFloat = 32) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let image = downsample(data, maxDimension: maxDimension) else { return nil }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return (pixels, width, height)
    }

    private static func downsample(_ data: Data, maxDimension: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}
