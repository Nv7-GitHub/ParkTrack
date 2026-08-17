import SwiftUI
import SwiftData
import MapKit
import CoreLocation

/// The app's signature screen: every cached park on a live map, layered with the overlays
/// that make progress legible — explored bubbles, fog of war, radius completion rings.
///
/// Two constraints shape the structure. MapKit search is expensive and rate-limited, so
/// discovery only runs when the camera settles and only on ground we haven't covered
/// before (`MapScanCoordinator`). And SwiftUI annotations degrade badly past a few hundred
/// pins, so only what is actually on screen is rendered, visited parks first.
@MainActor
struct MapScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(LocationProvider.self) private var location
    @Environment(AppSettings.self) private var settings
    @Environment(ServiceHub.self) private var services
    @Query private var parks: [Park]

    @State private var camera: MapCameraPosition = .automatic
    /// Updated only when the camera stops, so the annotation set doesn't churn mid-pan.
    @State private var settledRegion: MKCoordinateRegion?
    /// Updated on every camera frame, but only while fog needs to be re-projected.
    @State private var liveRegion: MKCoordinateRegion?

    @State private var layers = MapLayerOptions()
    @State private var completionsCache = DerivedCache<[RadiusCompletion]>()
    @State private var visibleCache = DerivedCache<[Park]>()
    @State private var revealedCache = DerivedCache<[Park]>()
    @State private var scanner = MapScanCoordinator()

    private var discovery: ParkDiscoveryService? { services.discovery }

    @State private var sheet: MapSheet?
    @State private var showsLayersPanel = false
    @State private var droppedPin: CLLocationCoordinate2D?
    @State private var selectedParkIdentifier: String?

    @State private var bulkMode = false
    @State private var bulkSelection: Set<String> = []

    @State private var searchText = ""
    @State private var searchResults: [ParkCandidate] = []
    @State private var searchTask: Task<Void, Never>?

    @State private var hasCenteredOnUser = false
    @State private var hapticTick = 0

    /// Past this many pins the map stops being readable and starts being slow.
    /// Ceilings for the widest zoom. Both scale down as the camera pulls back — see
    /// `annotationLimit(for:)`. Every annotation is a real SwiftUI view and every fog hole is
    /// a real overlay, so drawing hundreds of them while the map is moving is what made
    /// panning stutter, and at that zoom they are an indistinguishable blob anyway.
    private static let annotationLimit = 300
    private static let revealLimit = 250

    /// How many pins are worth drawing at a given zoom.
    ///
    /// Span is in degrees of latitude: roughly 0.05 is a neighbourhood, 0.5 a metro area, 2 a
    /// small state. Past that the pins overlap into a solid mass, so more of them buys the
    /// user nothing and costs a frame.
    nonisolated static func annotationLimit(forSpan span: MKCoordinateSpan?) -> Int {
        guard let span else { return 80 }
        switch span.latitudeDelta {
        case ..<0.08: return annotationLimit
        case ..<0.35: return 150
        case ..<1.2: return 60
        default: return 30
        }
    }

    private enum MapSheet: Identifiable {
        case detail(Park)
        case log(Park)
        case addPark(CLLocationCoordinate2D)

        var id: String {
            switch self {
            case .detail(let park): return "detail-\(park.identifier)"
            case .log(let park): return "log-\(park.identifier)"
            case .addPark(let coordinate): return "add-\(coordinate.latitude)-\(coordinate.longitude)"
            }
        }
    }

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                mapView
                    .simultaneousGesture(dropPinGesture(proxy: proxy))
                    .overlay {
                        if layers.fogOfWar {
                            FogOfWarOverlay(holes: fogHoles(proxy: proxy))
                        }
                    }
                    .overlay { controlOverlay }
            }
            .ignoresSafeArea(.keyboard)
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: toggleBulkMode) {
                        Image(systemName: bulkMode ? "checklist.checked" : "checklist")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .accessibilityLabel(bulkMode ? "Exit bulk logging" : "Bulk log visits")
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search parks")
            .onSubmit(of: .search, runSearch)
            .onChange(of: searchText) { _, newValue in
                if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    searchTask?.cancel()
                    searchResults = []
                }
            }
            .sheet(item: $sheet) { active in
                sheetContent(for: active)
            }
            .sheet(isPresented: $showsLayersPanel) {
                MapLayersPanel(
                    options: $layers,
                    visitedCount: parks.filter(\.isVisited).count,
                    totalCount: parks.count
                )
            }
            .sensoryFeedback(.impact, trigger: hapticTick)
            .task { await prepare() }
            .onDisappear { scanner.cancel() }
        }
    }

    // MARK: - Map

    private var mapView: some View {
        Map(position: $camera, interactionModes: .all) {
            mapContent
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls {
            MapCompass()
        }
        .onMapCameraChange(frequency: .continuous) { context in
            guard layers.fogOfWar else { return }
            liveRegion = context.region
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            settledRegion = context.region
            liveRegion = context.region
            scheduleScan(for: context.region)
        }
    }

    @MapContentBuilder
    private var mapContent: some MapContent {
        UserAnnotation()
        ringContent
        parkContent
        droppedPinContent
    }

    @MapContentBuilder
    private var ringContent: some MapContent {
        if layers.showsRadiusRings, let anchor = anchorCoordinate {
            ForEach(radiusCompletions) { completion in
                MapCircle(center: anchor, radius: completion.radiusMiles * Format.metersPerMile)
                    .foregroundStyle(Theme.sky.opacity(0.04))
                    .stroke(Theme.sky.opacity(0.5), lineWidth: 1.5)

                Annotation("", coordinate: ringLabelCoordinate(anchor: anchor, radiusMiles: completion.radiusMiles)) {
                    RadiusRingLabel(completion: completion)
                }
                .annotationTitles(.hidden)
            }
        }
    }

    @MapContentBuilder
    private var parkContent: some MapContent {
        ForEach(visibleParks, id: \.identifier) { park in
            Annotation("", coordinate: park.coordinate, anchor: .center) {
                ParkMarker(
                    park: park,
                    isSelected: selectedParkIdentifier == park.identifier,
                    isBulkSelected: bulkSelection.contains(park.identifier)
                )
                // An overlay rather than a stack: the label must not shift the pin off the
                // coordinate it is marking.
                .overlay(alignment: .bottom) {
                    if showsParkNames {
                        ParkNameLabel(name: park.name, isVisited: park.isVisited)
                            .offset(y: 26)
                    }
                }
                .onTapGesture { handleTap(on: park) }
            }
            .annotationTitles(.hidden)
        }
    }

    /// Names are legible when there are few enough of them to read. Tied to the settled
    /// camera rather than the live one so panning never re-lays out every label mid-gesture.
    private var showsParkNames: Bool {
        switch layers.parkNames {
        case .never: return false
        case .always: return true
        case .automatic:
            guard let span = settledRegion?.span else { return false }
            return span.latitudeDelta < 0.055 && visibleParks.count <= 40
        }
    }

    @MapContentBuilder
    private var droppedPinContent: some MapContent {
        if let droppedPin {
            Annotation("", coordinate: droppedPin) {
                DroppedPinMarker()
            }
            .annotationTitles(.hidden)
        }
    }

    // MARK: - Overlay chrome

    private var controlOverlay: some View {
        VStack(spacing: 10) {
            topBanner
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                Spacer(minLength: 0)
                controlCluster
            }
            if bulkMode {
                BulkModeBar(
                    count: bulkSelection.count,
                    onConfirm: commitBulkVisits,
                    onCancel: cancelBulkMode
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .animation(.smooth(duration: 0.3), value: bulkMode)
    }

    private var controlCluster: some View {
        VStack(spacing: 12) {
            MapControlButton(
                systemImage: "location.fill",
                label: "Recenter map",
                action: recenter
            )
            MapControlButton(
                systemImage: "square.3.layers.3d",
                label: "Map layers",
                isActive: layers.fogOfWar,
                action: { showsLayersPanel = true }
            )
            MapControlButton(
                systemImage: "checklist",
                label: bulkMode ? "Exit bulk logging" : "Bulk log visits",
                isActive: bulkMode,
                badge: bulkSelection.isEmpty ? nil : "\(bulkSelection.count)",
                action: toggleBulkMode
            )
        }
    }

    @ViewBuilder
    private var topBanner: some View {
        VStack(spacing: 8) {
            if !searchResults.isEmpty {
                searchResultsCard
            }
            if scanner.isScanning {
                MapStatusPill(text: "Scanning this area…", showsSpinner: true)
            } else if bulkMode {
                MapStatusPill(text: "Tap every park you've been to", systemImage: "hand.tap.fill")
            } else if let message = discovery?.lastError {
                MapStatusPill(text: message, systemImage: "exclamationmark.triangle.fill")
            }
        }
        .animation(.smooth(duration: 0.3), value: scanner.isScanning)
        .animation(.smooth(duration: 0.3), value: searchResults.count)
    }

    private var searchResultsCard: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(searchResults) { candidate in
                    MapSearchResultRow(
                        candidate: candidate,
                        distanceMeters: distance(to: candidate.coordinate)
                    ) {
                        fly(to: candidate)
                    }
                    if candidate.id != searchResults.last?.id {
                        Divider().overlay(Theme.separator).padding(.leading, 56)
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 260)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
    }

    @ViewBuilder
    private func sheetContent(for active: MapSheet) -> some View {
        switch active {
        case .detail(let park):
            ParkQuickLookSheet(park: park) { present(.log(park)) }
        case .log(let park):
            LogVisitSheet(park: park) { finishLogging() }
        case .addPark(let coordinate):
            AddParkHereSheet(coordinate: coordinate) { name in
                addPark(named: name, at: coordinate)
            }
        }
    }

    // MARK: - Derived data

    private var anchorCoordinate: CLLocationCoordinate2D? {
        location.currentLocation?.coordinate ?? settings.homeCoordinate
    }

    private var radiusCompletions: [RadiusCompletion] {
        guard let anchor = anchorCoordinate else { return [] }
        return completionsCache.value(
            for: StatsSignature(
                parkCount: parks.count,
                visitCount: modelContext.visitCount(),
                anchor: anchor,
                extra: settings.radiiMiles
            )
        ) {
            StatsEngine.radiusCompletions(parks: parks, center: anchor, radiiMiles: settings.radiiMiles)
        }
    }

    /// Only what's on screen, and when even that is too much, visited parks win: the
    /// filled-in pins are the ones carrying the user's progress.
    private var visibleParks: [Park] {
        visibleCache.value(for: viewportSignature) {
            let limit = Self.annotationLimit(forSpan: settledRegion?.span)
            let pool = layers.showsUnvisited ? parks : parks.filter(\.isVisited)
            guard let region = settledRegion else {
                return Array(prioritised(pool).prefix(limit))
            }
            let inView = pool.filter { Self.region(region, contains: $0.coordinate, padding: 1.15) }
            guard inView.count > limit else { return inView }
            return Array(prioritised(inView).prefix(limit))
        }
    }

    /// Everything the two viewport scans depend on. Panning changes it; a location tick, a
    /// sheet opening or a scroll does not — and those were re-filtering every cached park.
    private var viewportSignature: StatsSignature {
        StatsSignature(
            parkCount: parks.count,
            visitCount: modelContext.visitCount(),
            anchor: settledRegion?.center,
            extra: [
                settledRegion?.span.latitudeDelta ?? 0,
                settledRegion?.span.longitudeDelta ?? 0,
                layers.showsUnvisited ? 1 : 0,
                layers.fogOfWar ? 1 : 0,
                layers.revealRadiusMiles
            ]
        )
    }

    /// Fog holes reach beyond the viewport, so they're gathered from a wider box than the
    /// annotations — a hole whose centre is just off screen still clears part of the screen.
    private var revealedParks: [Park] {
        revealedCache.value(for: viewportSignature) {
            // Fog holes are overlays composited every frame, so they get the same treatment.
            let limit = min(Self.revealLimit, Self.annotationLimit(forSpan: settledRegion?.span))
            let visited = parks.filter(\.isVisited)
            guard let region = settledRegion else { return Array(visited.prefix(limit)) }
            let nearby = visited.filter { Self.region(region, contains: $0.coordinate, padding: 1.8) }
            return Array(nearby.prefix(limit))
        }
    }

    private func prioritised(_ list: [Park]) -> [Park] {
        list.filter(\.isVisited) + list.filter { !$0.isVisited }
    }

    private func distance(to coordinate: CLLocationCoordinate2D) -> CLLocationDistance? {
        guard let origin = location.currentLocation else { return nil }
        return CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude).distance(from: origin)
    }

    /// Ring labels sit on the northern edge of their ring so they never stack on each other.
    private func ringLabelCoordinate(anchor: CLLocationCoordinate2D, radiusMiles: Double) -> CLLocationCoordinate2D {
        let metersNorth = radiusMiles * Format.metersPerMile
        return CLLocationCoordinate2D(
            latitude: anchor.latitude + metersNorth / 111_320,
            longitude: anchor.longitude
        )
    }

    /// Projects the explored bubbles into screen space for the fog layer to subtract.
    private func fogHoles(proxy: MapProxy) -> [FogOfWarOverlay.FogHole] {
        _ = liveRegion
        let radiusMeters = layers.revealRadiusMeters
        return revealedParks.compactMap { park in
            guard let center = proxy.convert(park.coordinate, to: .local) else { return nil }
            let edgeCoordinate = CLLocationCoordinate2D(
                latitude: park.coordinate.latitude + radiusMeters / 111_320,
                longitude: park.coordinate.longitude
            )
            guard let edge = proxy.convert(edgeCoordinate, to: .local) else { return nil }
            let radius = abs(edge.y - center.y)
            guard radius > 1 else { return nil }
            return FogOfWarOverlay.FogHole(center: center, radius: radius)
        }
    }

    private static func region(
        _ region: MKCoordinateRegion,
        contains coordinate: CLLocationCoordinate2D,
        padding: Double
    ) -> Bool {
        let latSlack = region.span.latitudeDelta * padding / 2
        let lonSlack = region.span.longitudeDelta * padding / 2
        return abs(coordinate.latitude - region.center.latitude) <= latSlack
            && abs(coordinate.longitude - region.center.longitude) <= lonSlack
    }

    // MARK: - Lifecycle

    private func prepare() async {
        guard !hasCenteredOnUser else { return }

        if let coordinate = anchorCoordinate {
            hasCenteredOnUser = true
            camera = .region(Self.defaultRegion(around: coordinate))
            return
        }
        if let resolved = await location.resolveLocation() {
            hasCenteredOnUser = true
            withAnimation(.smooth(duration: 0.6)) {
                camera = .region(Self.defaultRegion(around: resolved.coordinate))
            }
        }
    }

    private static func defaultRegion(around coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(center: coordinate, latitudinalMeters: 8_000, longitudinalMeters: 8_000)
    }

    private func scheduleScan(for region: MKCoordinateRegion) {
        guard let discovery else { return }
        scanner.scheduleScan(of: region) { target in
            _ = await discovery.discoverParks(in: target)
        }
    }

    // MARK: - Interaction

    private func handleTap(on park: Park) {
        hapticTick += 1
        if bulkMode {
            withAnimation(.smooth(duration: 0.2)) {
                if bulkSelection.contains(park.identifier) {
                    bulkSelection.remove(park.identifier)
                } else {
                    bulkSelection.insert(park.identifier)
                }
            }
            return
        }
        withAnimation(.smooth(duration: 0.25)) {
            selectedParkIdentifier = park.identifier
        }
        present(.detail(park))
    }

    private func dropPinGesture(proxy: MapProxy) -> some Gesture {
        LongPressGesture(minimumDuration: 0.45)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onEnded { value in
                guard case .second(true, let drag?) = value,
                      let coordinate = proxy.convert(drag.startLocation, from: .local) else { return }
                dropPin(at: coordinate)
            }
    }

    private func dropPin(at coordinate: CLLocationCoordinate2D) {
        guard !bulkMode else { return }
        hapticTick += 1
        withAnimation(.smooth(duration: 0.25)) {
            droppedPin = coordinate
        }
        present(.addPark(coordinate))
    }

    private func addPark(named name: String, at coordinate: CLLocationCoordinate2D) {
        guard let discovery else { return }
        let park = discovery.park(named: name, at: coordinate)
        try? modelContext.save()
        droppedPin = nil
        selectedParkIdentifier = park.identifier
        present(.log(park))
    }

    private func finishLogging() {
        sheet = nil
        droppedPin = nil
    }

    /// Swapping the presented sheet outright animates badly, so an already-open sheet is
    /// dismissed first and the next one presented once it has left the screen.
    private func present(_ next: MapSheet) {
        guard sheet != nil else {
            sheet = next
            return
        }
        sheet = nil
        Task {
            try? await Task.sleep(for: .milliseconds(340))
            sheet = next
        }
    }

    private func recenter() {
        hapticTick += 1
        if let coordinate = anchorCoordinate {
            withAnimation(.smooth(duration: 0.7)) {
                camera = .region(Self.defaultRegion(around: coordinate))
            }
        } else {
            location.requestAuthorization()
            location.start()
            withAnimation(.smooth(duration: 0.7)) {
                camera = .userLocation(fallback: .automatic)
            }
        }
    }

    private func fly(to candidate: ParkCandidate) {
        guard let discovery else { return }
        let park = discovery.park(for: candidate)
        try? modelContext.save()

        searchTask?.cancel()
        searchResults = []
        searchText = ""
        selectedParkIdentifier = park.identifier

        withAnimation(.smooth(duration: 0.8)) {
            camera = .region(
                MKCoordinateRegion(center: candidate.coordinate, latitudinalMeters: 1_800, longitudinalMeters: 1_800)
            )
        }
    }

    private func runSearch() {
        guard let discovery else { return }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        searchTask?.cancel()
        searchTask = Task {
            let results = await discovery.searchParks(
                named: query,
                near: anchorCoordinate ?? settledRegion?.center
            )
            guard !Task.isCancelled else { return }
            searchResults = Array(results.prefix(12))
        }
    }

    // MARK: - Bulk logging

    private func toggleBulkMode() {
        hapticTick += 1
        withAnimation(.smooth(duration: 0.3)) {
            bulkMode.toggle()
            if !bulkMode { bulkSelection.removeAll() }
            selectedParkIdentifier = nil
        }
    }

    private func cancelBulkMode() {
        withAnimation(.smooth(duration: 0.3)) {
            bulkMode = false
            bulkSelection.removeAll()
        }
    }

    /// One dated-today visit per selected park: the point of this flow is catching up on a
    /// backlog, not describing each trip, so nothing else is asked for.
    private func commitBulkVisits() {
        let today = Date()
        let selected = bulkSelection
        for park in parks where selected.contains(park.identifier) {
            modelContext.insert(Visit(date: today, park: park))
        }
        try? modelContext.save()
        hapticTick += 1
        withAnimation(.smooth(duration: 0.35)) {
            bulkSelection.removeAll()
            bulkMode = false
        }
    }
}
