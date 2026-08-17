import SwiftUI
import SwiftData
import CoreLocation

/// The full versions of Home's two summarised sections.
///
/// Home shows a handful of each — a carousel of suggestions, five recent visits — because
/// the front door should be readable at a glance. But a handful is a sample, and the
/// obvious thing to do with a sample is ask for the rest, so both headers push here.
enum HomeListRoute: Hashable {
    case recommendations
    case recentVisits
}

/// A section header that pushes to its own full list. Tappable across its whole width, with
/// a chevron, because a header that leads somewhere has to look like it does.
struct SectionHeaderLink<Value: Hashable>: View {
    let title: String
    var subtitle: String?
    let value: Value

    var body: some View {
        NavigationLink(value: value) {
            SectionHeader(title: title, subtitle: subtitle) {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows the full list")
    }
}

// MARK: - Somewhere new

/// Every suggestion the engine has, not just the ones that fit in the carousel.
///
/// It re-runs the engine rather than carrying the carousel's eight through the navigation:
/// a deeper list is a different question, and asking for more of them is exactly when the
/// diversity cap matters most.
struct HomeRecommendationsListView: View {
    @Environment(LocationProvider.self) private var location
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Park.name) private var parks: [Park]
    @State private var cache = DerivedCache<[Recommendation]>()

    /// Enough to browse, bounded so an enormous catalogue cannot make the screen expensive.
    private static let limit = 40

    private var originLocation: CLLocation? {
        location.currentLocation
            ?? settings.homeCoordinate.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
    }

    private var recommendations: [Recommendation] {
        let signature = StatsSignature(
            parkCount: parks.count,
            visitCount: modelContext.visitCount(),
            anchor: originLocation?.coordinate,
            extra: settings.radiiMiles
        )
        return cache.value(for: signature) {
            RecommendationEngine.recommendations(
                parks: parks,
                origin: originLocation,
                home: settings.homeCoordinate,
                radiiMiles: settings.radiiMiles,
                limit: Self.limit
            )
        }
    }

    var body: some View {
        let rows = recommendations

        Group {
            if rows.isEmpty {
                EmptyStateView(
                    systemImage: "sparkles",
                    title: "Nothing to suggest yet",
                    message: "Suggestions come from the parks near you that you haven't been to. Scan the map around you and they fill in."
                )
            } else {
                List(rows) { recommendation in
                    NavigationLink(value: recommendation.park) {
                        HomeRecommendationRow(recommendation: recommendation)
                    }
                    .listRowBackground(Theme.surface)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Go somewhere new")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The carousel card laid out as a row, so a long list reads down the page instead of
/// making the reader parse a grid of boxes.
struct HomeRecommendationRow: View {
    let recommendation: Recommendation

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: recommendation.reason.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(recommendation.reason.tint)
                .frame(width: 34, height: 34)
                .background(recommendation.reason.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(recommendation.park.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Text(recommendation.detail)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Pill(
                    text: recommendation.headline,
                    systemImage: recommendation.reason.systemImage,
                    tint: recommendation.reason.tint
                )
            }

            Spacer(minLength: 8)

            if let meters = recommendation.distanceMeters {
                Text(Format.distance(meters))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(recommendation.park.name). \(recommendation.headline).")
        .accessibilityValue(recommendation.detail)
    }
}

extension RecommendationReason {
    /// Shared by the carousel card and the list row so a reason always looks the same.
    var tint: Color {
        switch self {
        case .wishlist: return Theme.sunset
        case .finishRadius: return Theme.fern
        case .finishRegion: return Theme.moss
        case .closest: return Theme.sky
        case .newTerritory: return Theme.bark
        case .weekendPick: return Theme.canopy
        }
    }

    var systemImage: String {
        switch self {
        case .wishlist: return "star.fill"
        case .finishRadius: return "circle.dashed"
        case .finishRegion: return "map"
        case .closest: return "figure.walk"
        case .newTerritory: return "flag"
        case .weekendPick: return "sun.max"
        }
    }
}

// MARK: - Recently visited

/// Every visit ever logged, newest first.
///
/// Its own unbounded query: Home's is deliberately capped at the handful it shows, and
/// widening that one would make the front door pay for a screen it isn't displaying.
struct HomeRecentVisitsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Visit.date, order: .reverse) private var visits: [Visit]
    @State private var cache = DerivedCache<[Visit]>()

    private var ordered: [Visit] {
        let signature = StatsSignature(parkCount: 0, visitCount: modelContext.visitCount())
        return cache.value(for: signature) {
            visits.filter { $0.park != nil }.orderedByRecency()
        }
    }

    var body: some View {
        let rows = ordered

        Group {
            if rows.isEmpty {
                EmptyStateView(
                    systemImage: "figure.walk.motion",
                    title: "Your log starts here",
                    message: "Log a visit and it lands here with the date, the place and any photos you took."
                )
            } else {
                List(rows, id: \.identifier) { visit in
                    if let park = visit.park {
                        NavigationLink(value: park) {
                            HomeVisitHistoryRow(visit: visit, park: park)
                        }
                        .listRowBackground(Theme.surface)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(rows.count == 1 ? "1 visit" : "\(rows.count) visits")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One logged visit in the full history.
struct HomeVisitHistoryRow: View {
    let visit: Visit
    let park: Park

    var body: some View {
        HStack(spacing: 12) {
            HomeMediaThumbnail(visit: visit, size: 46)

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
                    Text(visit.isUndated ? "Marked visited" : Format.date(visit.date))
                    if visit.rating > 0 {
                        Text("·")
                        HStack(spacing: 1) {
                            ForEach(0..<visit.rating, id: \.self) { _ in
                                Image(systemName: "star.fill").font(.system(size: 8))
                            }
                        }
                        .foregroundStyle(Theme.sunset)
                    }
                    if visit.hasMedia {
                        Text("·")
                        Image(systemName: "photo").font(.system(size: 9))
                    }
                }
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(park.name), \(visit.isUndated ? "marked visited, no date" : Format.date(visit.date))"
        )
    }
}
