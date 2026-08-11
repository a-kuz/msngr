import Foundation
import CoreGraphics
import ImageIO

/// Обёртка CGImage для NSCache (требует class-тип).
private final class ImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// Конвейер изображений: даунсемплинг + forced decode вне главного потока, кэш в памяти.
/// На memory warning вызывающая сторона дергает clearMemory().
public final class ImagePipeline: @unchecked Sendable {
    public static let shared = ImagePipeline()

    private let cache = NSCache<NSString, ImageBox>()
    private let lock = NSLock()
    private var inflight: [String: Task<CGImage?, Never>] = [:]

    public init() {
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    /// Декодирует изображение с даунсемплингом до targetPixelSize (пиксели) вне главного потока.
    /// Результат — готовый к отрисовке CGImage, кэшируется в память.
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

    /// Синхронно из памяти, если уже декодировано (мгновенный показ при reuse ячейки).
    public func cachedImage(at url: URL, targetPixelSize: CGSize) -> CGImage? {
        cache.object(forKey: Self.key(url, targetPixelSize) as NSString)?.image
    }

    /// Фоновый прогрев кэша с низким приоритетом.
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

    /// Даунсемплинг через ImageIO: декод сразу в уменьшенный размер, без загрузки полного кадра.
    /// kCGImageSourceShouldCacheImmediately — forced decode без offscreen-рендера.
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

/// Подготовка изображений к отправке и вспомогательные преобразования.
public enum ImageProcessor {
    /// Даунскейл + JPEG для отправки: длинная сторона до maxDimension, качество 0.8.
    /// Возвращает (jpegData, размер в пикселях). Вход — данные любого поддерживаемого формата.
    public static func prepareForSending(_ data: Data, maxDimension: CGFloat = 1280) -> (data: Data, size: CGSize)? {
        guard let image = downsample(data, maxDimension: maxDimension) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
        let properties = [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, CGSize(width: image.width, height: image.height))
    }

    /// RGBA8-пиксели уменьшенной копии (для BlurHash-энкода), длинная сторона ~32px.
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
