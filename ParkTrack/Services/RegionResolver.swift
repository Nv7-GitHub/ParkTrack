import Foundation
import CoreLocation
import SwiftData

/// Fills in the city / county / state fields the stats screens group by.
///
/// `CLGeocoder` is rate-limited far more aggressively than it documents, and going over the
/// limit gets the whole app throttled rather than just failing one lookup. So every request
/// in the app funnels through this one serialized queue with a deliberate gap between calls,
/// and each park is geocoded exactly once (`Park.regionResolvedAt` is the receipt).
///
/// The geocoder returns whatever administrative divisions exist wherever the park is, so
/// this stays correct outside any one country.
@MainActor
final class RegionResolver {
    static let shared = RegionResolver()

    /// Apple throttles around one request per second; 1.2s leaves headroom.
    private static let minimumInterval: TimeInterval = 1.2

    private let geocoder = CLGeocoder()
    private let locationManager = CLLocationManager()
    private var lastRequestAt: Date?
    /// Tail of the serial queue. Every unit of work awaits its predecessor.
    private var queue: Task<Void, Never> = Task {}

    private init() {}

    /// Resolves up to `limit` unresolved parks, visited ones first and then nearest to the
    /// user, so the screens someone is most likely looking at fill in first.
    func resolveMissingRegions(context: ModelContext, limit: Int) async {
        guard limit > 0 else { return }

        let descriptor = FetchDescriptor<Park>(predicate: #Predicate { $0.regionResolvedAt == nil })
        guard let pending = try? context.fetch(descriptor), !pending.isEmpty else { return }

        let origin = locationManager.location
        let ordered = pending.sorted { lhs, rhs in
            if lhs.isVisited != rhs.isVisited { return lhs.isVisited }
            guard let origin else { return lhs.name < rhs.name }
            return lhs.distance(from: origin) < rhs.distance(from: origin)
        }

        for park in ordered.prefix(limit) {
            await resolve(park)
        }
    }

    func resolve(_ park: Park) async {
        guard park.regionResolvedAt == nil else { return }
        await enqueue { [weak self] in
            guard let self else { return }
            guard park.regionResolvedAt == nil else { return }
            await self.throttle()
            await self.performReverseGeocode(park)
        }
    }

    // MARK: - Serialization

    private func enqueue(_ work: @escaping @MainActor () async -> Void) async {
        let previous = queue
        let task = Task { @MainActor in
            await previous.value
            await work()
        }
        queue = task
        await task.value
    }

    private func throttle() async {
        if let lastRequestAt {
            let elapsed = Date().timeIntervalSince(lastRequestAt)
            if elapsed < Self.minimumInterval {
                try? await Task.sleep(for: .seconds(Self.minimumInterval - elapsed))
            }
        }
        lastRequestAt = Date()
    }

    private func performReverseGeocode(_ park: Park) async {
        guard let placemark = try? await geocoder.reverseGeocodeLocation(park.location).first else {
            // Leaving `regionResolvedAt` nil lets a later pass retry; a throttled failure
            // is temporary and shouldn't permanently blank out a park's region.
            return
        }

        park.locality = placemark.locality
        park.subAdministrativeArea = placemark.subAdministrativeArea
        park.administrativeArea = placemark.administrativeArea
        park.country = placemark.country
        park.postalAddress = Self.addressLine(from: placemark) ?? park.postalAddress
        park.regionResolvedAt = Date()

        if let context = park.modelContext, context.hasChanges {
            try? context.save()
        }
    }

    /// Built by hand rather than via `CNPostalAddressFormatter` so the string stays a simple
    /// one-liner and we avoid pulling in Contacts just for formatting.
    private static func addressLine(from placemark: CLPlacemark) -> String? {
        let street = [placemark.subThoroughfare, placemark.thoroughfare]
            .compactMap { $0 }
            .joined(separator: " ")
        let cityState = [placemark.locality, placemark.administrativeArea]
            .compactMap { $0 }
            .joined(separator: ", ")
        let parts = [street, cityState, placemark.postalCode, placemark.country]
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
