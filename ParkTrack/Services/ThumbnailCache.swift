import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Decoded, downsampled previews of stored media, kept in memory and produced off the
/// main thread.
///
/// A `MediaItem` holds a full-size photo — a couple of megabytes of HEIC or JPEG. Drawing
/// it in a 52-point list row previously meant `UIImage(data:)` inside `body`: a full
/// decode of the whole image, on the main thread, repeated for every row and again on
/// every body evaluation, with the result thrown away each time. A screen of rows with
/// photos could spend well over a frame's budget before laying anything out, which is what
/// made scrolling any list of visits stutter.
///
/// `CGImageSourceCreateThumbnailAtIndex` decodes straight to the size actually needed, so
/// the work is a fraction of a full decode, and the answer is then kept.
actor ThumbnailCache {
    static let shared = ThumbnailCache()

    /// Bounded by cost rather than count: a few hundred small bitmaps is fine, a few
    /// hundred large ones is not.
    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    /// Requests already running, so ten rows scrolling past the same photo decode it once.
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    /// Sizes are quantised so a 52pt and a 50pt request share one decode.
    private static func key(_ identifier: String, _ pixels: Int) -> String {
        "\(identifier)@\(pixels)"
    }

    private static func pixelSize(for size: CGFloat, scale: CGFloat) -> Int {
        let raw = Int((size * max(scale, 1)).rounded(.up))
        // Round up to the next multiple of 32: a handful of buckets rather than one per
        // caller, which keeps the hit rate high across screens that ask for similar sizes.
        return max(32, ((raw + 31) / 32) * 32)
    }

    /// An already-decoded thumbnail, if there is one. Cheap enough to call from `body`.
    @MainActor
    static func cached(identifier: String, size: CGFloat, scale: CGFloat) -> UIImage? {
        let pixels = pixelSize(for: size, scale: scale)
        return MainActorThumbnailMirror.shared.image(forKey: key(identifier, pixels))
    }

    /// Decodes if necessary, coalescing duplicate requests for the same image and size.
    func thumbnail(identifier: String, data: Data, size: CGFloat, scale: CGFloat) async -> UIImage? {
        let pixels = Self.pixelSize(for: size, scale: scale)
        let key = Self.key(identifier, pixels)

        if let existing = cache.object(forKey: key as NSString) {
            await MainActorThumbnailMirror.shared.store(existing, forKey: key)
            return existing
        }
        if let running = inFlight[key] {
            return await running.value
        }

        let task = Task<UIImage?, Never>.detached(priority: .userInitiated) {
            Self.downsample(data: data, toPixels: pixels)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil

        if let image {
            cache.setObject(image, forKey: key as NSString, cost: pixels * pixels * 4)
            await MainActorThumbnailMirror.shared.store(image, forKey: key)
        }
        return image
    }

    /// Decodes only as many pixels as will actually be drawn.
    private nonisolated static func downsample(data: Data, toPixels pixels: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels
        ] as CFDictionary

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            // Not every blob is something ImageIO can thumbnail (a video poster written by
            // an older build, for instance), so fall back to a plain decode.
            return UIImage(data: data)
        }
        return UIImage(cgImage: thumbnail)
    }
}

/// A main-thread-readable mirror of the cache.
///
/// The store itself is an actor so decoding never touches the main thread, but a view's
/// `body` cannot await. This lets a row draw an already-decoded thumbnail on its very
/// first frame instead of flashing a placeholder every time it is rebuilt.
@MainActor
final class MainActorThumbnailMirror {
    static let shared = MainActorThumbnailMirror()

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, forKey key: String) {
        let pixels = Int(image.size.width * image.size.height)
        cache.setObject(image, forKey: key as NSString, cost: max(pixels * 4, 1))
    }
}
