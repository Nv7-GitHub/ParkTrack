import SwiftUI
import UIKit

/// One shared visit, as it appears in the feed and on a friend's detail screen.
///
/// The friend's name is hidden on the detail screen, where repeating it on every row
/// would just be noise.
struct FriendVisitRow: View {
    let visit: FriendVisit
    var showsFriendName: Bool = true

    @State private var thumbnail: UIImage?
    @State private var isShowingMedia = false

    private var friendName: String? {
        let name = visit.friend?.displayName ?? ""
        return name.isEmpty ? nil : name
    }

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    if showsFriendName, let friendName {
                        HStack(spacing: 6) {
                            FriendAvatar(name: friendName, size: 22)
                            Text(friendName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                    }

                    Text(visit.parkName)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        if let region = visit.regionLabel, !region.isEmpty {
                            Pill(text: region, systemImage: "mappin.and.ellipse")
                        }
                        Text(dateLabel)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }

                    if !visit.note.isEmpty {
                        Text(visit.note)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if visit.rating > 0 {
                        FriendRatingStars(rating: visit.rating)
                    }
                }

                Spacer(minLength: 0)

                if let thumbnail {
                    Button {
                        isShowingMedia = true
                    } label: {
                        FriendMediaThumbnail(image: thumbnail, isVideo: visit.mediaIsVideo)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        visit.mediaIsVideo
                            ? "Play video from \(visit.parkName)"
                            : "View photo from \(visit.parkName)"
                    )
                }
            }
        }
        .task(id: visit.identifier) { await loadThumbnail() }
        .fullScreenCover(isPresented: $isShowingMedia) {
            FriendMediaViewer(visit: visit)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
    }

    /// A marked-visited park carries the moment its owner tapped, which is not a claim
    /// about when they were there — so the row says what actually happened rather than
    /// rendering that timestamp as "2 hours ago". Same wording as the user's own log.
    private var dateLabel: String {
        visit.isUndated ? "Marked visited" : Format.relative(visit.date)
    }

    private var accessibilitySummary: String {
        var parts: [String] = []
        if showsFriendName, let friendName { parts.append(friendName) }
        parts.append(visit.parkName)
        if let region = visit.regionLabel, !region.isEmpty { parts.append(region) }
        parts.append(visit.isUndated ? "marked visited, no date" : Format.relative(visit.date))
        return parts.joined(separator: ", ")
    }

    /// Videos ship as bytes rather than as a poster frame, so a frame has to be pulled
    /// out before the row can draw anything.
    private func loadThumbnail() async {
        guard let data = visit.mediaData, !data.isEmpty else {
            thumbnail = nil
            return
        }
        if visit.mediaIsVideo {
            guard let poster = await MediaCapture.videoThumbnail(from: data) else { return }
            thumbnail = UIImage(data: poster)
        } else {
            thumbnail = UIImage(data: data)
        }
    }
}

/// Square media preview with a play badge for video.
struct FriendMediaThumbnail: View {
    let image: UIImage
    var isVideo: Bool = false
    var size: CGFloat = 78

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: Theme.tightCornerRadius, style: .continuous))
            .overlay {
                if isVideo {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: Theme.tightCornerRadius, style: .continuous)
                    .strokeBorder(Theme.separator, lineWidth: 0.5)
            )
    }
}

/// Five-star rating, drawn small enough to sit inside a feed row.
struct FriendRatingStars: View {
    let rating: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { index in
                Image(systemName: index <= rating ? "star.fill" : "star")
                    .font(.caption2)
                    .foregroundStyle(index <= rating ? Theme.sunset : Theme.separator)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rated \(rating) out of 5")
    }
}
