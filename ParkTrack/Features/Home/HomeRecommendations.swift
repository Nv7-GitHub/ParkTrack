import SwiftUI

/// Horizontal carousel of "go here next" suggestions.
struct HomeRecommendations: View {
    let recommendations: [Recommendation]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(recommendations) { recommendation in
                    NavigationLink(value: recommendation.park) {
                        HomeRecommendationCard(recommendation: recommendation)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
    }
}

/// One suggestion: what the park is, why it's being suggested, and how far it is.
struct HomeRecommendationCard: View {
    let recommendation: Recommendation

    private var tint: Color {
        switch recommendation.reason {
        case .wishlist: return Theme.sunset
        case .finishRadius: return Theme.fern
        case .finishRegion: return Theme.moss
        case .closest: return Theme.sky
        case .newTerritory: return Theme.bark
        case .weekendPick: return Theme.canopy
        }
    }

    private var icon: String {
        switch recommendation.reason {
        case .wishlist: return "star.fill"
        case .finishRadius: return "circle.dashed"
        case .finishRegion: return "map"
        case .closest: return "figure.walk"
        case .newTerritory: return "flag"
        case .weekendPick: return "sun.max"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Pill(text: recommendation.headline, systemImage: icon, tint: tint)
                Spacer(minLength: 0)
            }

            Text(recommendation.park.name)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(recommendation.detail)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                if let meters = recommendation.distanceMeters {
                    Image(systemName: "location")
                        .font(.caption2.weight(.semibold))
                    Text(Format.distance(meters))
                        .font(.caption.weight(.semibold))
                } else if let region = recommendation.park.regionLabel {
                    Image(systemName: "mappin")
                        .font(.caption2.weight(.semibold))
                    Text(region)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.textSecondary.opacity(0.6))
            }
            .foregroundStyle(tint)
        }
        .padding(16)
        .frame(width: 232, height: 186, alignment: .topLeading)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(recommendation.park.name). \(recommendation.headline).")
        .accessibilityValue(recommendation.detail)
    }
}
