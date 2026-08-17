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
                    Text(Format.relative(visit.date))
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
        .accessibilityLabel("\(park.name), \(Format.date(visit.date))")
        .accessibilityHint("Opens the park")
    }
}

/// Square thumbnail for a visit: its first photo, a video poster frame, or a leaf glyph.
struct HomeMediaThumbnail: View {
    let visit: Visit
    var size: CGFloat = 50

    private var image: UIImage? {
        guard let media = visit.sortedMedia.first else { return nil }
        if let thumbnail = media.thumbnailData, let image = UIImage(data: thumbnail) { return image }
        guard !media.isVideo, let data = media.data else { return nil }
        return UIImage(data: data)
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
            if visit.sortedMedia.first?.isVideo == true {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: size * 0.34))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }
}
