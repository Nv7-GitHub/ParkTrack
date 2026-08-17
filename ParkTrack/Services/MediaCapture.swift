import AVFoundation
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Turns whatever the photo picker or camera hands us into something small enough to
/// live inside SwiftData and cheap enough to sync to friends.
///
/// Every entry point is failable rather than throwing: media is an optional nicety on a
/// visit, so a malformed asset should quietly produce nothing instead of blocking a log.
enum MediaCapture {
    /// Longest-edge downscale plus a re-encode, preferring HEIC where the device can write it.
    static func compressImage(_ data: Data, maxDimension: CGFloat = 2048) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scaled = downscale(image, maxDimension: maxDimension)
        return encode(scaled)
    }

    /// Re-encodes to at most 960x540 and trims to the first `maxSeconds`.
    static func compressVideo(at url: URL, maxSeconds: Double = 20) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset960x540) else {
            return nil
        }

        if let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > maxSeconds {
            let limit = CMTime(seconds: maxSeconds, preferredTimescale: duration.timescale)
            session.timeRange = CMTimeRange(start: .zero, duration: limit)
        }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: output) }

        do {
            try await session.export(to: output, as: .mp4)
            return try Data(contentsOf: output, options: .mappedIfSafe)
        } catch {
            return nil
        }
    }

    /// Poster frame taken slightly into the clip, since frame zero is often a blur.
    static func videoThumbnail(from data: Data) async -> Data? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: url) }
        return await videoThumbnail(atURL: url)
    }

    static func makeMediaItem(fromImage data: Data) -> MediaItem? {
        guard let compressed = compressImage(data) else { return nil }
        return MediaItem(data: compressed, isVideo: false)
    }

    static func makeMediaItem(fromVideoAt url: URL) async -> MediaItem? {
        guard let compressed = await compressVideo(at: url) else { return nil }
        var thumbnail = await videoThumbnail(atURL: url)
        if thumbnail == nil { thumbnail = await videoThumbnail(from: compressed) }
        return MediaItem(data: compressed, isVideo: true, thumbnailData: thumbnail)
    }

    // MARK: Internals

    private static func videoThumbnail(atURL url: URL) async -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1024, height: 1024)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1.0, preferredTimescale: 600)
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: time).image else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.8)
    }

    /// Draws through `UIGraphicsImageRenderer`, which bakes the orientation into the pixels.
    private static func downscale(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0, size.width > 0, size.height > 0 else { return image }

        let scale = maxDimension / longest
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private static func encode(_ image: UIImage) -> Data? {
        if supportsHEIC, let heic = heicData(from: image) { return heic }
        return image.jpegData(compressionQuality: 0.8)
    }

    private static let supportsHEIC: Bool = {
        let types = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return types.contains(UTType.heic.identifier)
    }()

    private static func heicData(from image: UIImage) -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.heic.identifier as CFString, 1, nil
        ) else { return nil }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.8,
            kCGImagePropertyOrientation: CGImagePropertyOrientation(image.imageOrientation).rawValue
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

/// Square-ish preview for a single `MediaItem`, shared by the visit list, the visit
/// detail sheet and the friend feed so attachments read identically everywhere.
struct MediaThumbnail: View {
    let item: MediaItem
    var size: CGFloat = 84
    var cornerRadius: CGFloat = Theme.tightCornerRadius

    private var previewImage: UIImage? {
        let source = item.isVideo ? (item.thumbnailData ?? item.data) : item.data
        return source.flatMap(UIImage.init(data:))
    }

    var body: some View {
        ZStack {
            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Theme.separator
                Image(systemName: item.isVideo ? "video.slash" : "photo")
                    .font(.system(size: size * 0.28, weight: .light))
                    .foregroundStyle(Theme.textSecondary)
            }

            if item.isVideo {
                Image(systemName: "play.fill")
                    .font(.system(size: size * 0.22, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(size * 0.14)
                    .background(.ultraThinMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.isVideo ? "Video attachment" : "Photo attachment")
    }
}
