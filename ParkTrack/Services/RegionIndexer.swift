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
    private(set) var lastError: String?

    /// A state is far too large to sweep tile by tile in one go; indexing is offered for
    /// cities and counties, and a state's number stays the sum of what is known.
    static let indexableKinds: [RegionKind] = [.city, .county]

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
    func indexArea(around coordinate: CLLocationCoordinate2D) async {
        guard let placemark = await reverseGeocode(coordinate) else { return }
        for kind in Self.indexableKinds {
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
        guard activeRegionName == nil else { return nil }

        let identifier = RegionIndex.identity(kind: kind, name: name, container: container)
        var resolved = placemark
        if resolved == nil {
            resolved = await geocode([name, container].compactMap { $0 }.joined(separator: ", "))
        }
        guard let center = resolved?.location?.coordinate ?? fallbackCenter else {
            lastError = "Couldn't work out where \(name) is."
            return nil
        }

        let radius = Self.radiusMeters(for: resolved, kind: kind)
        let record = index(for: identifier) ?? {
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
            return fresh
        }()

        record.centerLatitude = center.latitude
        record.centerLongitude = center.longitude
        record.radiusMeters = radius
        record.isIndexing = true
        record.lastError = nil
        activeRegionName = record.displayName
        defer {
            record.isIndexing = false
            activeRegionName = nil
        }

        // Always forced, even for a first index. An unforced sweep skips ground the startup
        // pass already covered — but that pass tiles a 25-mile radius coarsely, and reusing
        // it would let a city be called "indexed" off a scan too sparse to have seen all of
        // it. Indexing is a claim that the place was searched properly, so it searches.
        _ = await discovery.sweep(
            around: center,
            radiusMiles: radius / Format.metersPerMile,
            force: true
        )

        // A cut-short sweep has not seen the whole place, and recording it as indexed would
        // publish a total that is simply wrong — including to friends racing against it.
        guard discovery.lastSweepCompleted, !Task.isCancelled else {
            record.lastError = "Indexing \(name) was interrupted. Try again."
            lastError = record.lastError
            try? modelContext.save()
            return nil
        }

        // A real city has parks in it. Zero means the sweep never actually saw the place —
        // `MKLocalSearch` treats its region as a hint rather than a bound and will happily
        // answer a query about somewhere far away with results from where the device is,
        // which the result filter then discards. Recording that as a completed index would
        // publish a total of zero, including to friends racing against it.
        let count = parkCount(matching: identifier, kind: kind)
        guard count > 0 else {
            record.lastError = "The map returned no parks in \(name). It may not have understood the area — try again."
            lastError = record.lastError
            record.indexedAt = nil
            try? modelContext.save()
            return nil
        }

        record.parkCount = count
        record.indexedAt = Date()
        record.lastError = nil
        try? modelContext.save()
        return record
    }

    /// Parks the sweep found that actually belong to this region. Membership comes from the
    /// park's own placemark, so a sweep circle overlapping the next town over doesn't
    /// inflate the count.
    private func parkCount(matching identifier: String, kind: RegionKind) -> Int {
        let parks = (try? modelContext.fetch(FetchDescriptor<Park>())) ?? []
        return parks.count { RegionIndex.identity(kind: kind, park: $0) == identifier }
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
