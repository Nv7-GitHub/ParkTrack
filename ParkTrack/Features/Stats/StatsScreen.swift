import SwiftUI
import SwiftData
import CoreLocation

/// The numbers tab: headline records, radius and region completion, growth over time,
/// visit rhythm, superlatives and a shareable year-in-review card.
///
/// Everything is computed from the cached parks by `StatsEngine`, so the screen recomputes
/// itself the moment SwiftData publishes a change and works with no network at all.
struct StatsScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(LocationProvider.self) private var location
    @Environment(AppSettings.self) private var settings

    @Query(sort: \Park.name) private var parks: [Park]

    @State private var anchor: StatsAnchor = .currentLocation
    @State private var droppedPin: CLLocationCoordinate2D?
    @State private var isPickingPin = false

    private var anchorCoordinate: CLLocationCoordinate2D? {
        switch anchor {
        case .currentLocation: return location.currentLocation?.coordinate
        case .home: return settings.homeCoordinate
        case .pin: return droppedPin
        }
    }

    private var anchorLocation: CLLocation? {
        anchorCoordinate.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
    }

    private var records: Records {
        StatsEngine.records(parks: parks, origin: anchorLocation)
    }

    private var streaks: Streaks {
        StatsEngine.streaks(parks: parks)
    }

    private var yearSummary: YearInReviewSummary {
        YearInReviewSummary.make(
            parks: parks,
            year: Calendar.current.component(.year, from: Date()),
            streakWeeks: streaks.currentWeeks,
            displayName: settings.displayName
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if parks.isEmpty {
                    EmptyStateView(
                        systemImage: "chart.bar.xaxis",
                        title: "Nothing to measure yet",
                        message: "Find parks near you on the Map tab. As soon as there are parks to visit, this tab fills with rings, curves and records."
                    )
                    .padding(.top, 60)
                } else {
                    LazyVStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                        headline

                        StatsRadiusSection(
                            parks: parks,
                            anchor: anchor,
                            anchorCoordinate: anchorCoordinate,
                            radiiMiles: settings.radiiMiles,
                            selectedAnchor: $anchor,
                            onDropPin: { isPickingPin = true }
                        )

                        StatsRegionSection(parks: parks)

                        StatsTimelineSection(parks: parks)

                        StatsRhythmSection(parks: parks)

                        StatsRecordsSection(records: records, streaks: streaks)

                        YearInReviewCard(summary: yearSummary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 36)
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Stats")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $isPickingPin) {
                StatsPinPickerSheet(
                    initialCoordinate: droppedPin ?? location.currentLocation?.coordinate ?? settings.homeCoordinate
                ) { coordinate in
                    droppedPin = coordinate
                    anchor = .pin
                }
            }
        }
        .task {
            _ = await location.resolveLocation()
            await RegionResolver.shared.resolveMissingRegions(context: modelContext, limit: 12)
        }
    }

    // MARK: Headline

    private var headline: some View {
        let stats = records
        let streak = streaks

        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                "Your collection",
                subtitle: stats.totalParks == 0
                    ? "Nothing logged yet — the first one is the hardest"
                    : "\(Format.parkCount(stats.totalParks)) visited so far"
            )

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 104), spacing: 10)],
                spacing: 10
            ) {
                StatTile(value: "\(stats.totalParks)", label: "Parks visited", systemImage: "tree.fill", tint: Theme.fern)
                StatTile(value: "\(stats.totalVisits)", label: "Total visits", systemImage: "figure.walk", tint: Theme.sky)
                StatTile(value: "\(stats.parksThisMonth)", label: "New this month", systemImage: "calendar", tint: Theme.moss)
                StatTile(value: "\(stats.parksThisYear)", label: "New this year", systemImage: "calendar.badge.clock", tint: Theme.bark)
                StatTile(value: "\(stats.distinctCities)", label: "Cities", systemImage: "building.2.fill", tint: Theme.sky)
                StatTile(value: "\(stats.distinctStates)", label: "States or regions", systemImage: "map.fill", tint: Theme.canopy)
                StatTile(value: "\(streak.currentWeeks)", label: "Week streak", systemImage: "flame.fill", tint: Theme.sunset)
                StatTile(value: "\(streak.longestWeeks)", label: "Longest streak", systemImage: "crown.fill", tint: Theme.sunset)
            }
            .animation(.smooth(duration: 0.45), value: stats.totalVisits)
        }
    }
}
