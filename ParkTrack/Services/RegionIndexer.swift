import Foundation
import CoreLocation
import MapKit
import Observation
import SwiftData

/// Sweeps a named place — a city, a county, a state — until every park in it has been
/// found, then records the total so it never has to be swept again.
///
/// The area comes from the geocoder's own region for the place rather than a radius the user
/// picked, which is the whole point: a completion percentage should describe Redmond, not
/// "the ten miles around wherever I was standing".
@Observable
@MainActor
final class RegionIndexer {
    private let modelContext: ModelContext
    private let discovery: ParkDiscoveryService
    private let geocoder = CLGeocoder()

    /// The region being swept right now, if any, so the UI can show progress and refuse to
    /// queue a second sweep on top of it.
    private(set) var activeRegionName: String?
    /// Identity of the region being swept, so a screen can tell whether the progress on show
    /// is its own. Without it every open sheet displayed whatever happened to be running.
    private(set) var activeRegionIdentifier: String?
    private(set) var lastError: String?
    /// Live progress of the sweep behind the active index, so the UI can show something
    /// moving rather than an indeterminate spinner for minutes.
    private(set) var progress: ParkDiscoveryService.SweepProgress?

    /// The running index, owned here rather than by whichever sheet started it.
    ///
    /// Every index used to be launched from a `Task` inside a view, which tied minutes of
    /// searching to the lifetime of a sheet the user is entitled to close. Indexing belongs
    /// to the service: the UI asks for it, watches `activeRegionName` and `progress`, and can
    /// come and go while it runs.
    private var indexTask: Task<Void, Never>?

    var isIndexing: Bool { indexTask != nil }

    /// Whether the sweep currently running is this region's, matched on identity and falling
    /// back to the name for a region that has no index record yet.
    func isIndexing(identifier: String?, name: String) -> Bool {
        guard activeRegionName != nil else { return false }
        if let identifier, let active = activeRegionIdentifier, !identifier.isEmpty {
            return identifier == active
        }
        return activeRegionName?.localizedCaseInsensitiveContains(name) ?? false
    }



    /// Where one region stands: waiting its turn, or being swept right now.
    enum State: Equatable {
        case queued(position: Int)
        case sweeping(ParkDiscoveryService.SweepProgress?)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case let (.queued(a), .queued(b)): return a == b
            case (.sweeping, .sweeping): return true
            default: return false
            }
        }
    }

    /// Regions asked for but not yet finished, oldest first. Kept so every region can report
    /// its own standing rather than sharing one bar between them.
    private(set) var pending: [(identifier: String, name: String)] = []

    /// Starts work in the background and returns immediately. Requests made while another is
    /// running wait their turn rather than being dropped, and say so.
    func enqueue(identifier: String, name: String, _ work: @escaping () async -> Void) {
        pending.append((identifier: identifier, name: name))
        let previous = indexTask
        indexTask = Task { [weak self] in
            await previous?.value
            await work()
            self?.pending.removeAll { $0.identifier == identifier && $0.name == name }
            if self?.pending.isEmpty == true {
                self?.indexTask = nil
            }
        }
    }

    /// What to show for one region: its own progress, its own place in the queue, or nothing.
    /// What is holding up the queue, if anything.
    var blockingRegionName: String? { activeRegionName }

    func state(forIdentifier identifier: String?, name: String) -> State? {
        if isIndexing(identifier: identifier, name: name) { return .sweeping(progress) }
        guard let position = pending.firstIndex(where: { entry in
            if let identifier, !identifier.isEmpty, entry.identifier == identifier { return true }
            return entry.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else { return nil }
        return .queued(position: position)
    }

    /// Waits for everything queued, for callers that need the result.
    func waitForIndexing() async {
        await indexTask?.value
    }

    /// A state is far too large to sweep tile by tile in one go; indexing is offered for
    /// cities and counties, and a state's number stays the sum of what is known.
    static let indexableKinds: [RegionKind] = [.city, .county]

    /// What gets indexed without being asked. Only the city.
    ///
    /// A county is hundreds of searches against a rate limit, so indexing one automatically on
    /// launch occupied the queue for many minutes — and anything the user then asked for sat
    /// behind it, apparently doing nothing. Counties are worth indexing, but only when someone
    /// chooses to wait for one.
    static let automaticKinds: [RegionKind] = [.city]

    init(modelContext: ModelContext, discovery: ParkDiscoveryService) {
        self.modelContext = modelContext
        self.discovery = discovery
    }

    // MARK: - Lookup

    func index(for identifier: String) -> RegionIndex? {
        let descriptor = FetchDescriptor<RegionIndex>(
            predicate: #Predicate { $0.identifier == identifier }
        )
        return try? modelContext.fetch(descriptor).first
    }

    func allIndexes() -> [RegionIndex] {
        let descriptor = FetchDescriptor<RegionIndex>(sortBy: [SortDescriptor(\.name)])
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    // MARK: - Indexing

    /// Indexes whatever city and county the coordinate falls in. This is the automatic path:
    /// wherever the user is gets indexed once, in the background, and then stays indexed.
    /// Places an older generation recorded, whose totals are no longer believed.
    ///
    /// Deliberately not swept automatically. Re-indexing a county is hundreds of searches and
    /// several minutes, and doing that unasked on launch — for every stale place at once —
    /// would hammer the map service and take control away from the user. Their totals are
    /// already distrusted, so the cost of waiting for a tap is only that a percentage stays
    /// marked partial until then.
    func outdatedIndexes() -> [RegionIndex] {
        allIndexes().filter(\.needsReindexing)
    }

    /// Re-sweeps every stale place. Called when the user asks, never on its own.
    func refreshOutdatedIndexes() async {
        let stale = allIndexes().filter(\.needsReindexing)
        for region in stale {
            if Task.isCancelled { return }
            await reindex(region)
        }
    }

    func indexArea(around coordinate: CLLocationCoordinate2D) async {
        guard let placemark = await reverseGeocode(coordinate) else { return }
        for kind in Self.automaticKinds {
            guard let name = placeName(from: placemark, kind: kind) else { continue }
            let identifier = RegionIndex.identity(
                kind: kind,
                name: name,
                container: kind == .state ? placemark.country : placemark.administrativeArea
            )
            if let existing = index(for: identifier), existing.isIndexed { continue }
            await indexPlace(
                name: name,
                kind: kind,
                container: placemark.administrativeArea,
                country: placemark.country,
                fallbackCenter: coordinate
            )
        }
    }

    /// Indexes a place the user named. Geocodes it first, so "Redmond" resolves to a real
    /// area with a real extent rather than a guess.
    @discardableResult
    func indexPlace(named query: String, kind: RegionKind = .city) async -> RegionIndex? {
        guard let placemark = await geocode(query) else {
            lastError = "Couldn't find a place called \"\(query)\"."
            return nil
        }
        // Prefer the field the user asked for, but accept what the geocoder actually named:
        // typing a county name often comes back with the county in `subAdministrativeArea`
        // and no locality at all, and vice versa.
        let resolvedKind: RegionKind = placeName(from: placemark, kind: kind) != nil
            ? kind
            : (placemark.subAdministrativeArea != nil ? .county : .city)
        guard let name = placeName(from: placemark, kind: resolvedKind) else {
            lastError = "\"\(query)\" didn't resolve to a \(kind.title.lowercased())."
            return nil
        }
        let kind = resolvedKind
        return await indexPlace(
            name: name,
            kind: kind,
            container: placemark.administrativeArea,
            country: placemark.country,
            fallbackCenter: placemark.location?.coordinate,
            placemark: placemark
        )
    }

    /// Indexes a suggestion picked from the search list.
    @discardableResult
    func indexSuggestion(_ suggestion: PlaceSuggestion, kind: RegionKind) async -> RegionIndex? {
        await indexPlace(named: suggestion.query, kind: kind)
    }

    /// Re-sweeps a region that was already indexed. Parks open and close; this is how a
    /// number that has gone stale gets corrected.
    func reindex(_ region: RegionIndex) async {
        await indexPlace(
            name: region.name,
            kind: region.kind,
            container: region.container,
            country: region.country,
            fallbackCenter: region.center,
            force: true
        )
    }

    @discardableResult
    private func indexPlace(
        name: String,
        kind: RegionKind,
        container: String?,
        country: String?,
        fallbackCenter: CLLocationCoordinate2D?,
        placemark: CLPlacemark? = nil,
        force: Bool = false
    ) async -> RegionIndex? {
        _ = force  // The sweep below is unconditionally forced; see the comment there.
        // Wait for any index already running instead of refusing outright, which is what
        // made a second tap report "couldn't index" with no explanation.
        while activeRegionName != nil {
            if Task.isCancelled { return nil }
            try? await Task.sleep(for: .milliseconds(200))
        }

        let identifier = RegionIndex.identity(kind: kind, name: name, container: container)
        let existing = index(for: identifier)

        // A place is geocoded once and then keeps the centre and radius it was given.
        //
        // The tile grid is derived entirely from those two numbers, and swept ground is
        // matched by containment — so a centre that moves even a few metres shifts every
        // tile off the ground already searched, and not one of them can be skipped. Since
        // `indexPlace` re-geocoded on every attempt, and `CLGeocoder` does not answer
        // identically twice, resuming a large region started again from nothing however
        // faithfully its coverage had been saved.
        //
        // It is also what the number means: the radius is the area the count is a count
        // *of*, and it is shared with friends racing the same place. It must not drift.
        let center: CLLocationCoordinate2D
        let radius: CLLocationDistance
        let record: RegionIndex

        if let existing, existing.radiusMeters > 0, CLLocationCoordinate2DIsValid(existing.center) {
            center = existing.center
            radius = existing.radiusMeters
            record = existing
        } else {
            var resolved = placemark
            if resolved == nil {
                resolved = await geocode([name, container].compactMap { $0 }.joined(separator: ", "))
            }
            guard let resolvedCenter = resolved?.location?.coordinate ?? fallbackCenter else {
                lastError = "Couldn't work out where \(name) is."
                return nil
            }
            center = resolvedCenter
            radius = Self.radiusMeters(for: resolved, kind: kind)

            if let existing {
                existing.centerLatitude = center.latitude
                existing.centerLongitude = center.longitude
                existing.radiusMeters = radius
                record = existing
            } else {
                let fresh = RegionIndex(
                    identifier: identifier,
                    kind: kind,
                    name: name,
                    container: container,
                    country: country ?? resolved?.country,
                    center: center,
                    radiusMeters: radius
                )
                modelContext.insert(fresh)
                record = fresh
            }
        }

        record.isIndexing = true
        record.lastError = nil
        activeRegionName = record.displayName
        activeRegionIdentifier = record.identifier
        defer {
            record.isIndexing = false
            activeRegionName = nil
            activeRegionIdentifier = nil
            progress = nil
        }

        // A uniform-density sweep, not the ordinary one. The ordinary sweep widens in levels
        // that grow threefold, so its outer tiles are tens of kilometres across and see only a
        // fraction of what is in them — which is how a county came to report itself fully
        // indexed while missing most of its parks. The sweep reuses any ground already
        // searched at this grade, including tiles from an earlier attempt that ran out of
        // time, and re-searches anything that was only skimmed.
        let result = await discovery.sweepDense(
            around: center,
            radiusMiles: radius / Format.metersPerMile,
            // What counts as this place, judged from the search result's own placemark —
            // the same test the final count uses, applied early enough to save the searches
            // rather than late enough only to discard them.
            belongsToRegion: { park in
                // Name first, container only as a tie-breaker. See `RegionIndex.place(kind:
                // park:isNamed:)`: the two sides get their container from different MapKit
                // calls, and one answering "WA" where the other says "Washington" made every
                // park in a city fail to belong to it.
                RegionIndex.place(kind: kind, park: park, isNamed: name)
                    || RegionIndex.identity(kind: kind, park: park) == identifier
            }
        ) { [weak self] update in
            self?.progress = update
        }
        progress = nil
        record.isApproximate = result.truncated

        // A cut-short sweep has not seen the whole place, and recording it as indexed would
        // publish a total that is simply wrong — including to friends racing against it.
        guard result.completed, !Task.isCancelled else {
            record.lastError = discovery.lastError
                ?? "Indexing \(name) stopped early. Try again in a moment."
            lastError = record.lastError
            try? modelContext.save()
            return nil
        }

        // A real city has parks in it. Zero means the sweep never actually saw the place —
        // `MKLocalSearch` treats its region as a hint rather than a bound and will happily
        // answer a query about somewhere far away with results from where the device is,
        // which the result filter then discards. Recording that as a completed index would
        // publish a total of zero, including to friends racing against it.
        let count = parkCount(matching: identifier, named: name, kind: kind)
        // Also catches a sweep that was refused rather than answered: throttled searches
        // return nothing, and nothing looks exactly like an empty city.
        guard count > 0 else {
            record.lastError = "The map returned no parks in \(name). It may not have understood the area — try again."
            lastError = record.lastError
            record.indexedAt = nil
            try? modelContext.save()
            return nil
        }

        record.parkCount = count
        record.indexedAt = Date()
        record.indexerVersion = RegionIndex.currentIndexerVersion
        record.lastError = nil
        try? modelContext.save()
        return record
    }

    /// Parks the sweep found that actually belong to this region. Membership comes from the
    /// park's own placemark, so a sweep circle overlapping the next town over doesn't
    /// inflate the count.
    private func parkCount(matching identifier: String, named name: String, kind: RegionKind) -> Int {
        let parks = (try? modelContext.fetch(FetchDescriptor<Park>())) ?? []
        return parks.count {
            RegionIndex.place(kind: kind, park: $0, isNamed: name)
                || RegionIndex.identity(kind: kind, park: $0) == identifier
        }
    }

    // MARK: - Geocoding

    private func geocode(_ query: String) async -> CLPlacemark? {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return try? await geocoder.geocodeAddressString(query).first
    }

    private func reverseGeocode(_ coordinate: CLLocationCoordinate2D) async -> CLPlacemark? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return try? await geocoder.reverseGeocodeLocation(location).first
    }

    private func placeName(from placemark: CLPlacemark, kind: RegionKind) -> String? {
        switch kind {
        case .city: return placemark.locality
        case .county: return placemark.subAdministrativeArea
        case .state: return placemark.administrativeArea
        }
    }

    /// How far to sweep. The geocoder gives a circular region for most places, which is the
    /// honest answer; the fallbacks are only for when it doesn't, and are clamped so one
    /// enormous county can't launch a sweep that never finishes.
    nonisolated static func radiusMeters(for placemark: CLPlacemark?, kind: RegionKind) -> CLLocationDistance {
        let fallback: CLLocationDistance = kind == .county ? 25_000 : 8_000
        guard let region = placemark?.region as? CLCircularRegion else { return fallback }
        return min(max(region.radius, 3_000), kind == .county ? 60_000 : 30_000)
    }
}
