import CoreLocation
import MapKit
import SwiftData
import SwiftUI

/// The Parks tab: the full catalogue of everything discovered nearby, sliced by whether
/// the user has been there.
///
/// All filter options are derived from the parks actually in the store, so the screen
/// works identically wherever the user lives — there is no baked-in list of places.
struct ParksListScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(LocationProvider.self) private var location
    @Environment(AppSettings.self) private var settings

    @Query private var parks: [Park]

    @State private var segment: ParkSegment = .visited
    @State private var sort: ParkSortOption = .distance
    @State private var searchText = ""
    @State private var cityFilter: String?
    @State private var stateFilter: String?
    @State private var requirePhotos = false
    @State private var loggingTarget: Park?
    @State private var isBulkAdding = false

    private var origin: CLLocation? {
        if let current = location.currentLocation { return current }
        if let home = settings.homeCoordinate {
            return CLLocation(latitude: home.latitude, longitude: home.longitude)
        }
        return nil
    }

    private var hasActiveFilters: Bool {
        cityFilter != nil || stateFilter != nil || requirePhotos
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if visible.isEmpty {
                        emptyState
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(visible, id: \.identifier) { park in
                            NavigationLink {
                                ParkDetailView(park: park)
                            } label: {
                                ParkRow(park: park, origin: origin)
                            }
                            .listRowBackground(Theme.surface)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button {
                                    loggingTarget = park
                                } label: {
                                    Label("Log Visit", systemImage: "plus.circle.fill")
                                }
                                .tint(Theme.fern)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    toggleWishlist(park)
                                } label: {
                                    Label(
                                        park.isWishlisted ? "Remove" : "Wishlist",
                                        systemImage: park.isWishlisted ? "bookmark.slash.fill" : "bookmark.fill"
                                    )
                                }
                                .tint(Theme.sunset)
                            }
                        }
                    }
                } header: {
                    listHeader
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Parks")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search parks and places")
            .safeAreaInset(edge: .top, spacing: 0) { segmentBar }
            .tabBarBottomInset()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isBulkAdding = true
                    } label: {
                        Image(systemName: "calendar.badge.plus")
                    }
                    .accessibilityLabel("Bulk add past visits")
                }
                ToolbarItem(placement: .topBarTrailing) { sortMenu }
                ToolbarItem(placement: .topBarTrailing) { filterMenu }
            }
            .sheet(item: $loggingTarget) { park in
                LogVisitSheet(park: park)
            }
            .sheet(isPresented: $isBulkAdding) {
                BulkAddVisitsSheet()
            }
        }
    }

    // MARK: Chrome

    private var segmentBar: some View {
        VStack(spacing: 0) {
            Picker("Segment", selection: $segment.animation(.smooth(duration: 0.25))) {
                ForEach(ParkSegment.allCases) { option in
                    Text("\(option.title) \(count(for: option))").tag(option)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
        }
        .background(.bar)
    }

    private var listHeader: some View {
        HStack(spacing: 6) {
            Text(Format.parkCount(visible.count))
            if hasActiveFilters || !searchText.isEmpty {
                Text("of \(count(for: segment))")
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            Text(sort.title)
                .foregroundStyle(Theme.textSecondary)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Theme.textPrimary)
        .textCase(nil)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(ParkSortOption.allCases) { option in
                    Label(option.title, systemImage: option.systemImage).tag(option)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort, currently \(sort.title)")
    }

    private var filterMenu: some View {
        Menu {
            Picker("City", selection: $cityFilter) {
                Text("All cities").tag(String?.none)
                ForEach(cities, id: \.self) { city in
                    Text(city).tag(String?.some(city))
                }
            }
            Picker("State or region", selection: $stateFilter) {
                Text("All regions").tag(String?.none)
                ForEach(states, id: \.self) { state in
                    Text(state).tag(String?.some(state))
                }
            }
            Toggle("Has photos", isOn: $requirePhotos)
            if hasActiveFilters {
                Divider()
                Button("Clear filters", systemImage: "xmark.circle") {
                    cityFilter = nil
                    stateFilter = nil
                    requirePhotos = false
                }
            }
        } label: {
            Image(systemName: hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(hasActiveFilters ? "Filters, active" : "Filters")
    }

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.isEmpty || hasActiveFilters {
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: "Nothing matches",
                message: "Try a different search, or clear the filters to see everything in this list.",
                actionTitle: hasActiveFilters ? "Clear filters" : nil,
                action: clearFiltersAction
            )
        } else {
            switch segment {
            case .visited:
                EmptyStateView(
                    systemImage: "figure.walk",
                    title: "No visits logged",
                    message: "Log a visit from any park's page, or backfill everything you've already done in one go.",
                    actionTitle: "Bulk add past visits",
                    action: { isBulkAdding = true }
                )
            case .notVisited:
                EmptyStateView(
                    systemImage: "map",
                    title: "Nothing left to explore",
                    message: "Every park we know about nearby has been visited. Open the Map tab and scan a wider area to find more."
                )
            case .wishlist:
                EmptyStateView(
                    systemImage: "bookmark",
                    title: "Your wishlist is empty",
                    message: "Swipe right on any park to save it here for later."
                )
            }
        }
    }

    // MARK: Data

    /// Nil when there is nothing to clear, so the empty state drops the button entirely.
    private var clearFiltersAction: (() -> Void)? {
        guard hasActiveFilters else { return nil }
        return {
            cityFilter = nil
            stateFilter = nil
            requirePhotos = false
        }
    }

    private func count(for segment: ParkSegment) -> Int {
        parks.filter(segment.matches).count
    }

    private var cities: [String] {
        Set(parks.compactMap { $0.locality }.filter { !$0.isEmpty }).sorted()
    }

    private var states: [String] {
        Set(parks.compactMap { $0.administrativeArea }.filter { !$0.isEmpty }).sorted()
    }

    private var visible: [Park] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = parks.filter { park in
            guard segment.matches(park) else { return false }
            if let cityFilter, park.locality != cityFilter { return false }
            if let stateFilter, park.administrativeArea != stateFilter { return false }
            if requirePhotos, !park.sortedVisits.contains(where: \.hasMedia) { return false }
            if !query.isEmpty {
                let matchesName = park.name.localizedCaseInsensitiveContains(query)
                let matchesRegion = (park.regionLabel ?? "").localizedCaseInsensitiveContains(query)
                if !matchesName && !matchesRegion { return false }
            }
            return true
        }
        return sort.apply(to: filtered, origin: origin)
    }

    // MARK: Mutations

    private func toggleWishlist(_ park: Park) {
        withAnimation(.smooth) { park.isWishlisted.toggle() }
        try? modelContext.save()
    }
}

/// The three ways the catalogue gets sliced.
enum ParkSegment: String, CaseIterable, Identifiable {
    case visited, notVisited, wishlist

    var id: String { rawValue }

    var title: String {
        switch self {
        case .visited: "Visited"
        case .notVisited: "To go"
        case .wishlist: "Wishlist"
        }
    }

    func matches(_ park: Park) -> Bool {
        switch self {
        case .visited: park.isVisited
        case .notVisited: !park.isVisited
        case .wishlist: park.isWishlisted
        }
    }
}

/// Sorting lives here rather than in the view so the comparators stay readable and the
/// "unknown goes last" rules are stated once.
enum ParkSortOption: String, CaseIterable, Identifiable {
    case distance, name, recentVisit, mostVisits, rating

    var id: String { rawValue }

    var title: String {
        switch self {
        case .distance: "Distance"
        case .name: "Name"
        case .recentVisit: "Most recent"
        case .mostVisits: "Most visits"
        case .rating: "Rating"
        }
    }

    var systemImage: String {
        switch self {
        case .distance: "location"
        case .name: "textformat"
        case .recentVisit: "clock"
        case .mostVisits: "repeat"
        case .rating: "star"
        }
    }

    func apply(to parks: [Park], origin: CLLocation?) -> [Park] {
        switch self {
        case .name:
            return parks.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .distance:
            guard let origin else { return ParkSortOption.name.apply(to: parks, origin: nil) }
            return parks.sorted { $0.distance(from: origin) < $1.distance(from: origin) }
        case .recentVisit:
            return parks.sorted { lhs, rhs in
                switch (lhs.lastVisitDate, rhs.lastVisitDate) {
                case let (l?, r?): return l > r
                case (nil, _?): return false
                case (_?, nil): return true
                default: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            }
        case .mostVisits:
            return parks.sorted { lhs, rhs in
                lhs.visitCount == rhs.visitCount
                    ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    : lhs.visitCount > rhs.visitCount
            }
        case .rating:
            return parks.sorted { lhs, rhs in
                switch (lhs.averageRating, rhs.averageRating) {
                case let (l?, r?):
                    return l == r ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending : l > r
                case (nil, _?): return false
                case (_?, nil): return true
                default: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            }
        }
    }
}

/// Backfills history in bulk: pick a date once, tick every park that belongs to it.
///
/// The two sources differ deliberately. "Nearby" lists parks already cached, which is what
/// most backfilling needs and works offline; "Search" goes out to the map so a park the user
/// visited on a trip can be added even though it was never discovered locally.
struct BulkAddVisitsSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(LocationProvider.self) private var location
    @Environment(AppSettings.self) private var settings
    @Environment(ServiceHub.self) private var services

    @Query private var parks: [Park]

    @State private var mode: Mode = .nearby

    private var discovery: ParkDiscoveryService? { services.discovery }

    @State private var query = ""
    @State private var candidates: [ParkCandidate] = []
    @State private var selection: Set<String> = []
    @State private var date = Date()
    @State private var isScanning = false
    @State private var searchTask: Task<Void, Never>?

    private enum Mode: String, CaseIterable, Identifiable {
        case nearby, search
        var id: String { rawValue }
        var title: String { self == .nearby ? "Nearby" : "Search" }
    }

    private var origin: CLLocation? {
        if let current = location.currentLocation { return current }
        if let home = settings.homeCoordinate {
            return CLLocation(latitude: home.latitude, longitude: home.longitude)
        }
        return nil
    }

    private var nearbyOptions: [BulkParkOption] {
        let sorted: [Park]
        if let origin {
            sorted = parks.sorted { $0.distance(from: origin) < $1.distance(from: origin) }
        } else {
            sorted = parks.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return sorted.prefix(80).map { park in
            BulkParkOption(
                id: park.identifier,
                name: park.name,
                subtitle: subtitle(region: park.regionLabel, coordinate: park.coordinate),
                coordinate: park.coordinate,
                candidate: nil
            )
        }
    }

    private var searchOptions: [BulkParkOption] {
        candidates.map { candidate in
            BulkParkOption(
                id: candidate.id,
                name: candidate.name,
                subtitle: candidate.addressLine ?? subtitle(region: nil, coordinate: candidate.coordinate),
                coordinate: candidate.coordinate,
                candidate: candidate
            )
        }
    }

    private var options: [BulkParkOption] { mode == .nearby ? nearbyOptions : searchOptions }

    /// Selected options can come from either tab, so both pools are searched when saving.
    private var selectedOptions: [BulkParkOption] {
        let pool = nearbyOptions + searchOptions
        var seen = Set<String>()
        return pool.filter { selection.contains($0.id) && seen.insert($0.id).inserted }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DatePicker("Visit date", selection: $date, displayedComponents: [.date])
                } header: {
                    Text("One date for all of them")
                } footer: {
                    Text("Every park you tick gets a visit logged on this date. Fine-tune individual visits afterwards.")
                }

                Section {
                    if options.isEmpty {
                        emptyRow
                    } else {
                        ForEach(options) { option in
                            Button {
                                toggle(option)
                            } label: {
                                BulkOptionRow(
                                    option: option,
                                    origin: origin,
                                    isSelected: selection.contains(option.id)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text(mode == .nearby ? "Nearby parks" : "Search results")
                        .textCase(nil)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Add Past Visits")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search parks anywhere")
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    Picker("Source", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    Divider()
                }
                .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selection.isEmpty ? "Save" : "Save \(selection.count)", action: save)
                        .fontWeight(.semibold)
                        .disabled(selection.isEmpty)
                }
            }
            .onChange(of: query) { _, newValue in
                mode = newValue.isEmpty ? mode : .search
                scheduleSearch(newValue)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var emptyRow: some View {
        if mode == .search {
            if discovery?.isSearching == true {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Searching the map…").foregroundStyle(Theme.textSecondary)
                }
            } else {
                EmptyStateView(
                    systemImage: "magnifyingglass",
                    title: query.isEmpty ? "Search anywhere" : "No matches",
                    message: query.isEmpty
                        ? "Type a park name to find it anywhere in the world, then tick it off."
                        : "Nothing came back for “\(query)”. Try a shorter or differently spelled name."
                )
                .listRowBackground(Color.clear)
            }
        } else {
            EmptyStateView(
                systemImage: "location.magnifyingglass",
                title: "No parks cached yet",
                message: "Scan around you to pull in the parks nearby, then tick off the ones you've already been to.",
                actionTitle: isScanning ? nil : "Find parks near me",
                action: scanAction
            )
            .listRowBackground(Color.clear)
        }
    }

    // MARK: Actions

    private var scanAction: (() -> Void)? {
        guard !isScanning else { return nil }
        return { Task { await scanNearby() } }
    }

    private func subtitle(region: String?, coordinate: CLLocationCoordinate2D) -> String? {
        if let region, !region.isEmpty { return region }
        return nil
    }

    private func toggle(_ option: BulkParkOption) {
        withAnimation(.smooth(duration: 0.2)) {
            if selection.contains(option.id) {
                selection.remove(option.id)
            } else {
                selection.insert(option.id)
            }
        }
    }

    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else {
            candidates = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let discovery else { return }
            let found = await discovery.searchParks(named: trimmed, near: origin?.coordinate)
            guard !Task.isCancelled else { return }
            candidates = found
        }
    }

    private func scanNearby() async {
        guard let discovery, let origin else { return }
        isScanning = true
        defer { isScanning = false }
        await discovery.discoverParks(around: origin.coordinate, radiusMiles: 5)
    }

    private func save() {
        guard let discovery else { return }
        for option in selectedOptions {
            let park: Park
            if let candidate = option.candidate {
                park = discovery.park(for: candidate)
            } else {
                park = discovery.park(named: option.name, at: option.coordinate)
            }
            let visit = Visit(date: date)
            modelContext.insert(visit)
            visit.park = park
        }
        try? modelContext.save()
        dismiss()
    }
}

/// A pickable park in the bulk flow, which may be cached locally or freshly found on the map.
private struct BulkParkOption: Identifiable {
    let id: String
    let name: String
    let subtitle: String?
    let coordinate: CLLocationCoordinate2D
    let candidate: ParkCandidate?
}

private struct BulkOptionRow: View {
    let option: BulkParkOption
    let origin: CLLocation?
    let isSelected: Bool

    private var distanceText: String? {
        guard let origin else { return nil }
        let target = CLLocation(latitude: option.coordinate.latitude, longitude: option.coordinate.longitude)
        return Format.distance(target.distance(from: origin))
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? Theme.accent : Theme.separator)
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 2) {
                Text(option.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                if let detail = [option.subtitle, distanceText].compactMap({ $0 }).first {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
