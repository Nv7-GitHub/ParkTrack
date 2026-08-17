import SwiftUI
import CoreLocation

/// One park as a list row.
///
/// Every list in the app (the Parks tab, map callouts, recommendation lists) renders parks
/// through this so distance, visit state and rating always read the same way. `origin` is
/// passed in rather than read from the environment because callers frequently already hold a
/// resolved location and recomputing it per row would thrash the location provider.
struct ParkRow: View {
    let park: Park
    let origin: CLLocation?

    private var distanceText: String? {
        guard let origin else { return nil }
        return Format.distance(park.distance(from: origin))
    }

    /// The most recent attachment, which is the one worth previewing.
    private var thumbnail: MediaItem? {
        for visit in park.sortedVisits {
            if let first = visit.sortedMedia.first { return first }
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 12) {
            leading

            VStack(alignment: .leading, spacing: 4) {
                Text(park.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if let region = park.regionLabel {
                        Text(region)
                            .lineLimit(1)
                    }
                    if park.regionLabel != nil, distanceText != nil {
                        Text("·")
                    }
                    if let distanceText {
                        Text(distanceText)
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

                HStack(spacing: 8) {
                    if park.visitCount > 0 {
                        Pill(
                            text: park.visitCount == 1 ? "1 visit" : "\(park.visitCount) visits",
                            systemImage: "checkmark.circle.fill",
                            tint: Theme.fern
                        )
                    }
                    if park.isWishlisted {
                        Pill(text: "Wishlist", systemImage: "bookmark.fill", tint: Theme.sunset)
                    }
                    ParkRatingDots(rating: park.averageRating)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var leading: some View {
        if let thumbnail {
            MediaThumbnail(item: thumbnail, size: 52, cornerRadius: 12)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(park.isVisited ? Theme.fern.opacity(0.18) : Theme.separator.opacity(0.6))
                Image(systemName: park.isVisited ? "tree.fill" : "tree")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(park.isVisited ? Theme.fern : Theme.textSecondary)
            }
            .frame(width: 52, height: 52)
        }
    }

    private var accessibilityLabel: String {
        var parts = [park.name]
        if let region = park.regionLabel { parts.append(region) }
        if let distanceText { parts.append(distanceText + " away") }
        parts.append(park.isVisited ? "Visited \(park.visitCount) time\(park.visitCount == 1 ? "" : "s")" : "Not visited")
        if let average = park.averageRating {
            parts.append("Rated \(String(format: "%.1f", average)) out of 5")
        }
        if park.isWishlisted { parts.append("On your wishlist") }
        return parts.joined(separator: ", ")
    }
}

/// Compact five-dot rating readout. Dots rather than stars so a row stays quiet next to
/// the pills beside it; the full star control lives in the log sheet.
struct ParkRatingDots: View {
    let rating: Double?
    var size: CGFloat = 7

    var body: some View {
        if let rating {
            HStack(spacing: 3) {
                ForEach(1...5, id: \.self) { index in
                    Circle()
                        .fill(Double(index) <= rating.rounded() ? Theme.sunset : Theme.separator)
                        .frame(width: size, height: size)
                }
            }
            .accessibilityHidden(true)
        }
    }
}
