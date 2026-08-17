import SwiftUI
import UIKit

/// The last handful of logged visits, newest first.
struct HomeRecentVisits: View {
    let visits: [Visit]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(visits.enumerated()), id: \.element.identifier) { index, visit in
                if let park = visit.park {
                    NavigationLink(value: park) {
                        row(visit: visit, park: park)
                    }
                    .buttonStyle(.plain)
                    if index != visits.count - 1 {
                        Divider().overlay(Theme.separator).padding(.leading, 78)
                    }
                }
            }
        }
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 0.5)
        )
    }

    private func row(visit: Visit, park: Park) -> some View {
        HStack(spacing: 14) {
            HomeMediaThumbnail(visit: visit)

            VStack(alignment: .leading, spacing: 3) {
                Text(park.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                if let region = park.regionLabel {
                    Text(region)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(visit.isUndated ? "Marked visited" : Format.relative(visit.date))
                    if visit.rating > 0 {
                        Text("·")
                        HStack(spacing: 1) {
                            ForEach(0..<visit.rating, id: \.self) { _ in
                                Image(systemName: "star.fill").font(.system(size: 8))
                            }
                        }
                        .foregroundStyle(Theme.sunset)
                    }
                }
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary.opacity(0.6))
        }
        .padding(14)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(park.name), \(visit.isUndated ? "marked visited, no date" : Format.date(visit.date))")
        .accessibilityHint("Opens the park")
    }
}

/// Square thumbnail for a visit: its first photo, a video poster frame, or a leaf glyph.
///
/// Decoding goes through `ThumbnailCache`, so the photo is read and downsampled once off
/// the main thread rather than being decoded at full size inside `body` on every pass.
struct HomeMediaThumbnail: View {
    let visit: Visit
    var size: CGFloat = 50

    @Environment(\.displayScale) private var displayScale
    @State private var decoded: UIImage?

    /// The earliest attachment, found in one pass — sorting the whole set to take its
    /// first element was pure waste on a row that only ever shows one.
    private var media: MediaItem? {
        (visit.media ?? []).min { $0.createdAt < $1.createdAt }
    }

    private var image: UIImage? {
        guard let media else { return nil }
        return decoded ?? ThumbnailCache.cached(
            identifier: media.identifier.uuidString,
            size: size,
            scale: displayScale
        )
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Theme.moss.opacity(0.14)
                Image(systemName: "leaf.fill")
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(Theme.moss)
            }
            if media?.isVideo == true {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: size * 0.34))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: visit.identifier) { await load() }
        .accessibilityHidden(true)
    }

    private func load() async {
        guard image == nil, let media else { return }
        let source = media.thumbnailData ?? (media.isVideo ? nil : media.data)
        guard let source, !source.isEmpty else { return }
        decoded = await ThumbnailCache.shared.thumbnail(
            identifier: media.identifier.uuidString,
            data: source,
            size: size,
            scale: displayScale
        )
    }
}
