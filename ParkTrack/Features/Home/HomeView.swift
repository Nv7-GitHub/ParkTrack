import SwiftUI
import SwiftData
import CoreLocation

/// The app's front door: where you are, how much of it you've seen, and the shortest path
/// to logging the visit you're probably standing in right now.
///
/// Everything on this screen derives from the user's own position — there is no notion of a
/// built-in place list — so the first appearance kicks a discovery pass around wherever they
/// happen to be and the screen fills itself in. Discovery never blocks: the sections render
/// from whatever is cached and a slim banner reports work in progress.
struct HomeView: View {
    /// Named space the hero measures its scroll offset in.
    static let scrollSpace = "home.scroll"

    @Environment(\.modelContext) private var modelContext
    @Environment(LocationProvider.self) private var location
    @Environment(AppSettings.self) private var settings
    @Environment(ServiceHub.self) private var services

    @Query(sort: \Park.name) private var parks: [Park]
    @State private var recordsCache = DerivedCache<Records>()
    @State private var streaksCache = DerivedCache<Streaks>()
    @State private var completionsCache = DerivedCache<[RadiusCompletion]>()
    @State private var recommendationsCache = DerivedCache<[Recommendation]>()
    @Query(sort: \Visit.date, order: .reverse) private var visits: [Visit]

    @State private var path = NavigationPath()
    @State private var logTarget: Park?
    /// Held until the presenting sheet is fully gone: iOS drops a sheet raised while
    /// another one is still dismissing.
    @State private var pendingLogTarget: Park?
    @State private var isSearchSheetPresented = false
    @State private var mapPurpose: HomeMapPickerSheet.Purpose?
    @State private var isFindingNearest = false
    @State private var notice: HomeNotice?
    @State private var hasRunInitialPass = false
    @State private var isSettingsPresented = false

    private var discovery: ParkDiscoveryService? { services.discovery }

    var body: some View {
        let records = self.records

        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: Theme.sectionSpacing) {
                    HomeHeroHeader(
                        greeting: greeting,
                        subtitle: heroSubtitle,
                        totalParks: records.totalParks,
                        totalVisits: records.totalVisits,
                        cities: records.distinctCities,
                        streakWeeks: streaks.currentWeeks
                    )
                    .padding(.horizontal, 16)

                    aroundYouSection
                    logSection
                    recommendationSection
                    recentSection
                }
                .padding(.top, 8)
            }
            .coordinateSpace(.named(Self.scrollSpace))
            .scrollIndicators(.hidden)
            .tabBarBottomInset()
            .background(Theme.background)
            .refreshable { await runDiscovery(force: false) }
            .overlay(alignment: .top) { activityBanner }
            .overlay(alignment: .topTrailing) { settingsButton }
            .animation(.smooth(duration: 0.3), value: isSearching)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Park.self) { park in
                ParkDetailView(park: park)
            }
            .navigationDestination(for: HomeRadiusRoute.self) { route in
                HomeRadiusDetailView(route: route)
            }
            .sheet(item: $logTarget) { park in
                LogVisitSheet(park: park) {
                    try? modelContext.save()
                }
            }
            .sheet(isPresented: $isSearchSheetPresented, onDismiss: promotePendingTarget) {
                if let discovery {
                    HomeParkSearchSheet(discovery: discovery, near: anchorCoordinate) { park in
                        pendingLogTarget = park
                    }
                }
            }
            .sheet(item: $mapPurpose, onDismiss: promotePendingTarget) { purpose in
                if let discovery {
                    HomeMapPickerSheet(
                        purpose: purpose,
                        discovery: discovery,
                        start: anchorCoordinate,
                        onPickPark: { pendingLogTarget = $0 },
                        onPickCoordinate: { coordinate in
                            settings.homeCoordinate = coordinate
                            Task { await runDiscovery(force: false) }
                        }
                    )
                }
            }
            .alert(
                notice?.title ?? "",
                isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } }),
                presenting: notice
            ) { notice in
                if notice.offersSearch {
                    Button("Find by name") { isSearchSheetPresented = true }
                }
                Button("OK", role: .cancel) {}
            } message: { notice in
                Text(notice.message)
            }
            .task(id: discovery == nil) { await firstAppearance() }
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsScreen()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var aroundYouSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Around you", subtitle: ringSubtitle)
                .padding(.horizontal, 16)

            if let anchorCoordinate {
                if parks.isEmpty {
                    firstRunCard.padding(.horizontal, 16)
                } else {
                    HomeRadiusRings(completions: completions, center: anchorCoordinate)
                }
            } else {
                HomeLocationPrompt(
                    isAuthorized: location.isAuthorized,
                    onEnableLocation: {
                        location.requestAuthorization()
                        location.start()
                        Task { await runDiscovery(force: false) }
                    },
                    onSetHome: { mapPurpose = .setHome }
                )
                .padding(.horizontal, 16)
            }
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Log a visit", subtitle: "Three taps from here to a saved memory")
                .padding(.horizontal, 16)

            HomeQuickActions(
                isLocating: isFindingNearest,
                onHereNow: { Task { await logHereNow() } },
                onFindByName: { isSearchSheetPresented = true },
                onPickOnMap: { mapPurpose = .logVisit }
            )
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var recommendationSection: some View {
        if !recommendations.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Go somewhere new", subtitle: "Picked from what's near and what's unfinished")
                    .padding(.horizontal, 16)
                HomeRecommendations(recommendations: recommendations)
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Recently visited")
                .padding(.horizontal, 16)

            Group {
                if recentVisits.isEmpty {
                    Card(padding: 0) {
                        EmptyStateView(
                            systemImage: "figure.walk.motion",
                            title: "Your log starts here",
                            message: "Log a visit and it lands here with the date, the place and any photos you took."
                        )
                    }
                } else {
                    HomeRecentVisits(visits: recentVisits)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var firstRunCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: isSearching ? "binoculars" : "map")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.accent)
                Text(isSearching ? "Looking around you…" : "No parks found yet")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(isSearching
                     ? "We're sweeping the map around you for parks. Rings and suggestions appear as they arrive."
                     : "Pull down to search the map around you, or add the first park by name.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Search near me") { Task { await runDiscovery(force: true) } }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .disabled(isSearching)
                    Button("Add by name") { isSearchSheetPresented = true }
                        .buttonStyle(.bordered)
                        .tint(Theme.accent)
                }
                .font(.subheadline.weight(.medium))
            }
        }
    }

    /// Sits over the hero because Home hides the navigation bar to let the gradient
    /// run to the top of the screen.
    private var settingsButton: some View {
        Button {
            isSettingsPresented = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        }
        .padding(.trailing, 20)
        .padding(.top, 8)
        .accessibilityLabel("Settings")
    }

    @ViewBuilder
    private var activityBanner: some View {
        if isSearching {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text("Finding parks near you")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityLabel("Finding parks near you")
        }
    }

    // MARK: - Derived data

    private var anchorCoordinate: CLLocationCoordinate2D? {
        location.currentLocation?.coordinate ?? settings.homeCoordinate
    }

    private var originLocation: CLLocation? {
        location.currentLocation
            ?? settings.homeCoordinate.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
    }

    // Each of these costs milliseconds over a few hundred parks and none of them change
    // between one body evaluation and the next unless the data or the anchor moved, so they
    // go through a cache keyed on exactly that. See DerivedCache.
    private var statsSignature: StatsSignature {
        StatsSignature(
            parkCount: parks.count,
            visitCount: modelContext.visitCount(),
            anchor: anchorCoordinate,
            extra: settings.radiiMiles
        )
    }

    private var records: Records {
        recordsCache.value(for: statsSignature) {
            StatsEngine.records(parks: parks, origin: originLocation)
        }
    }

    private var streaks: Streaks {
        streaksCache.value(for: statsSignature) {
            StatsEngine.streaks(parks: parks)
        }
    }

    private var completions: [RadiusCompletion] {
        guard let anchorCoordinate else { return [] }
        return completionsCache.value(for: statsSignature) {
            StatsEngine.radiusCompletions(
                parks: parks,
                center: anchorCoordinate,
                radiiMiles: settings.radiiMiles
            )
        }
    }

    private var recommendations: [Recommendation] {
        recommendationsCache.value(for: statsSignature) {
            RecommendationEngine.recommendations(
                parks: parks,
                origin: originLocation,
                home: settings.homeCoordinate,
                radiiMiles: settings.radiiMiles,
                limit: 8
            )
        }
    }

    private var recentVisits: [Visit] {
        Array(visits.filter { $0.park != nil }.prefix(5))
    }

    private var isSearching: Bool {
        discovery?.isSearching ?? false
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let name = settings.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: String
        switch hour {
        case 0..<5: base = "Still out there"
        case 5..<12: base = "Good morning"
        case 12..<17: base = "Good afternoon"
        case 17..<22: base = "Good evening"
        default: base = "Good night"
        }
        return name.isEmpty ? base : "\(base), \(name)"
    }

    private var heroSubtitle: String {
        if records.totalParks == 0 {
            return "Every park you visit gets counted here."
        }
        if let last = streaks.lastVisitDate {
            return "Last visit \(Format.relative(last))"
        }
        return "\(Format.parkCount(records.totalParks)) and counting"
    }

    private var ringSubtitle: String {
        guard anchorCoordinate != nil else { return "Completion by distance" }
        return location.currentLocation != nil
            ? "Completion within reach of where you are"
            : "Completion around your home pin"
    }

    // MARK: - Actions

    /// Runs again when the shared hub finishes wiring up, since `RootView`'s task can
    /// land after this screen has already appeared.
    private func firstAppearance() async {
        location.requestAuthorization()
        location.start()

        guard discovery != nil, !hasRunInitialPass else { return }
        hasRunInitialPass = true
        await runDiscovery(force: false)
    }

    /// Sweeps the map around the user, then fills in the region fields the new parks lack.
    ///
    /// The sweep covers the widest ring the user actually asks about, because a ring can
    /// only quote a percentage of ground that has been searched. Discovery tracks what it
    /// has already covered, so an unforced pass — a return to the tab, a pull to refresh —
    /// costs nothing over ground already swept and only widens when the rings do.
    private func runDiscovery(force: Bool) async {
        guard let discovery else { return }

        let center = await location.resolveLocation() ?? originLocation
        guard let coordinate = center?.coordinate ?? settings.homeCoordinate else { return }

        let radius = settings.radiiMiles.max() ?? AppSettings.defaultRadiiMiles.max() ?? 10
        await discovery.sweep(around: coordinate, radiusMiles: radius, force: force)
        await RegionResolver.shared.resolveMissingRegions(context: modelContext, limit: 30)
    }

    private func promotePendingTarget() {
        guard let park = pendingLogTarget else { return }
        pendingLogTarget = nil
        logTarget = park
    }

    private func logHereNow() async {
        guard let discovery else { return }
        isFindingNearest = true
        defer { isFindingNearest = false }

        guard let here = await location.resolveLocation() else {
            notice = HomeNotice(
                title: "No location yet",
                message: "We couldn't get a fix on where you are. Allow location access, or find the park by name.",
                offersSearch: true
            )
            return
        }

        // A generous radius: park boundaries are large and the map's pin usually sits at
        // the centre, not at the gate you walked in through.
        guard let park = await discovery.nearestPark(to: here.coordinate, within: 1_600) else {
            notice = HomeNotice(
                title: "Nothing found nearby",
                message: "No park within a mile of you is on the map. You can still add it by name.",
                offersSearch: true
            )
            return
        }
        logTarget = park
    }
}

/// A one-off message from a Home action, shown as an alert.
struct HomeNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var offersSearch: Bool = false
}
