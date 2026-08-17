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
    /// Computed once per render and passed down: every section needs the same answer to
    /// "did my inputs change", and working it out six times is itself measurable.
    private var statsSignature: StatsSignature {
        StatsSignature(
            parkCount: parks.count,
            visitCount: modelContext.visitCount(),
            anchor: anchorLocation?.coordinate
        )
    }

    @State private var cache = StatsCache()
    @Query private var indexes: [RegionIndex]

    // Used only while the shared cache is still warming, or before its first pass has run.
    // Without them a cold screen recomputed records, streaks and the year-in-review figures
    // on every body evaluation — and the year card was never in the shared cache at all, so
    // it walked every visit on every pass for the life of the screen.
    @State private var recordsFallback = DerivedCache<Records>()
    @State private var streaksFallback = DerivedCache<Streaks>()
    @State private var yearCache = DerivedCache<YearInReviewSummary>()

    @State private var anchor: StatsAnchor = .currentLocation
    @State private var droppedPin: CLLocationCoordinate2D?
    @State private var isPickingPin = false
    @State private var breakdown: StatBreakdownSheet.Kind?

    private var anchorCoordinate: CLLocationCoordinate2D? {
        switch anchor {
        case .currentLocation: return location.currentLocation?.coordinate
        case .place(let kind): return settings.coordinate(for: kind)
        case .pin: return droppedPin
        }
    }

    private var anchorLocation: CLLocation? {
        anchorCoordinate.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
    }

    private var records: Records {
        cache.records ?? recordsFallback.value(for: statsSignature) {
            StatsEngine.records(parks: parks, origin: anchorLocation)
        }
    }

    private var streaks: Streaks {
        cache.streaks ?? streaksFallback.value(for: statsSignature) {
            StatsEngine.streaks(parks: parks)
        }
    }

    private var yearSummary: YearInReviewSummary {
        let streakWeeks = streaks.currentWeeks
        let signature = StatsSignature(
            parkCount: parks.count,
            visitCount: modelContext.visitCount(),
            anchor: nil,
            extra: [Double(streakWeeks)],
            tokens: [settings.displayName]
        )
        return yearCache.value(for: signature) {
            YearInReviewSummary.make(
                parks: parks,
                year: Calendar.current.component(.year, from: Date()),
                streakWeeks: streakWeeks,
                displayName: settings.displayName
            )
        }
    }

    /// Computes the screen's figures once, off the tab transition. Without this the sections
    /// each did their own work the moment they were built, which froze the tab bar on the way
    /// in and hitched again at every section on the way down.
    private func warmCache() async {
        await cache.warm(
            parks: parks,
            signature: statsSignature,
            indexes: indexes,
            origin: anchorLocation,
            anchor: anchorCoordinate,
            radiiMiles: settings.radiiMiles,
            timelineMonths: 12
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if parks.isEmpty {
                    EmptyStateView(
                        systemImage: "chart.bar.xaxis",
                        title: "Nothing to measure yet",
                        message: "Find parks near you on the Map tab. As soon as there are parks to visit, this tab fills with rings, curves and records."
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                            headline

                            StatsRadiusSection(
                                parks: parks,
                                signature: statsSignature,
                                cache: cache,
                                anchor: anchor,
                                anchorCoordinate: anchorCoordinate,
                                radiiMiles: settings.radiiMiles,
                                selectedAnchor: $anchor,
                                onDropPin: { isPickingPin = true }
                            )

                            StatsRegionSection(parks: parks, signature: statsSignature, cache: cache)

                            StatsTimelineSection(parks: parks, signature: statsSignature, cache: cache)

                            StatsRhythmSection(parks: parks, signature: statsSignature, cache: cache)

                            StatsRecordsSection(records: records, streaks: streaks)

                            YearInReviewCard(summary: yearSummary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                    }
                }
            }
            .tabBarBottomInset()
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Stats")
            .navigationBarTitleDisplayMode(.large)
            .sheet(item: $breakdown) { kind in
                StatBreakdownSheet(kind: kind, parks: parks, origin: anchorLocation)
            }
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
            // Figures first, and only then the slow background errands, so the screen settles
            // before anything else competes for the main thread.
            await warmCache()
            _ = await location.resolveLocation()
            await warmCache()
            await RegionResolver.shared.resolveMissingRegions(context: modelContext, limit: 12)
        }
        .task(id: statsSignature) { await warmCache() }
        .task(id: anchor) { await warmCache() }
        // Removing the place you were measuring from would otherwise leave the screen
        // anchored to somewhere that no longer exists, with no segment to move off.
        .onChange(of: settings.savedPlaces) { _, places in
            if case .place(let kind) = anchor, !places.contains(kind) {
                anchor = .currentLocation
            }
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

            // Two columns, not an adaptive three. Eight tiles divide evenly into four rows,
            // where three left a stranded pair on the last row, and the extra width stops
            // labels like "States or regions" wrapping into the tile below.
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2),
                spacing: 10
            ) {
                // Every figure opens the set it counted. A headline number raises a question
                // it cannot answer on its own — seventeen cities, but which ones — and the
                // answer is already in the store.
                tile(.visitedParks, "\(stats.totalParks)", "Parks visited", "tree.fill", Theme.fern)
                tile(.allVisits, "\(stats.totalVisits)", "Total visits", "figure.walk", Theme.sky)
                tile(.newThisMonth, "\(stats.parksThisMonth)", "New this month", "calendar", Theme.moss)
                tile(.newThisYear, "\(stats.parksThisYear)", "New this year", "calendar.badge.clock", Theme.bark)
                tile(.cities, "\(stats.distinctCities)", "Cities", "building.2.fill", Theme.sky)
                tile(.states, "\(stats.distinctStates)", "States or regions", "map.fill", Theme.canopy)
                tile(.currentStreak, "\(streak.currentWeeks)", "Week streak", "flame.fill", Theme.sunset)
                tile(.longestStreak, "\(streak.longestWeeks)", "Longest streak", "crown.fill", Theme.sunset)
            }
            .animation(.smooth(duration: 0.45), value: stats.totalVisits)
        }
    }

    private func tile(
        _ kind: StatBreakdownSheet.Kind,
        _ value: String,
        _ label: String,
        _ systemImage: String,
        _ tint: Color
    ) -> some View {
        Button {
            breakdown = kind
        } label: {
            StatTile(value: value, label: label, systemImage: systemImage, tint: tint, showsDisclosure: true)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows the full list")
    }
}
