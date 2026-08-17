import XCTest
import MapKit
@testable import ParkTrack

/// Measures what tiling actually buys.
///
/// The indexer splits any tile whose answer comes back at the map's per-request cap, on the
/// theory that a saturated tile is hiding parks. That costs a pyramid of requests — the
/// coarse passes are re-searched ground once you know you will split — and the whole
/// question is whether the fine passes find anything the coarse ones missed.
///
/// Opt-in, because it spends real searches against a shared rate limit:
///
///     PARKTRACK_LIVE_PROBES=1 xcodebuild ... -only-testing:ParkTrackTests/TilingStrategyProbe test
final class TilingStrategyProbe: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PARKTRACK_LIVE_PROBES"] == "1",
            "Live map probes are opt-in; set PARKTRACK_LIVE_PROBES=1 to run them."
        )
    }

    /// San Francisco proper.
    private let city = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.7599, longitude: -122.4370),
        span: MKCoordinateSpan(latitudeDelta: 0.15, longitudeDelta: 0.16)
    )

    private struct Level {
        let side: Int
        var found: Set<String> = []
        var requests = 0
        var saturated = 0
        var seconds: Double = 0
    }

    /// One search, counted and filtered exactly as the app would.
    private func search(_ region: MKCoordinateRegion) async -> (parks: [String: String], raw: Int) {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "park"
        request.region = region
        request.resultTypes = .pointOfInterest
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.park, .nationalPark])

        do {
            let response = try await SearchThrottle.shared.run(request)
            var parks: [String: String] = [:]
            for item in response.mapItems {
                guard let name = item.name,
                      ParkDiscoveryService.isParkLike(name: name, category: item.pointOfInterestCategory)
                else { continue }
                let coordinate = item.placemark.coordinate
                guard CLLocationCoordinate2DIsValid(coordinate) else { continue }
                parks[Park.identity(name: name, coordinate: coordinate)] = name
            }
            return (parks, response.mapItems.count)
        } catch {
            print("PROBE search failed: \(error.localizedDescription)")
            return ([:], 0)
        }
    }

    private func run(side: Int) async -> Level {
        var level = Level(side: side)
        let start = Date()
        for tile in ParkDiscoveryService.tiles(for: city, side: side) {
            let (parks, raw) = await search(tile)
            level.requests += 1
            level.found.formUnion(parks.keys)
            if raw >= ParkDiscoveryService.saturatedResultCount { level.saturated += 1 }
        }
        level.seconds = Date().timeIntervalSince(start)
        return level
    }

    /// Does splitting a saturated tile actually find parks a coarser pass missed?
    func testWhatSplittingBuys() async throws {
        var levels: [Level] = []
        for side in [1, 3, 6] {
            let level = await run(side: side)
            levels.append(level)
            print(String(
                format: "PROBE side=%2d tiles=%3d requests=%3d saturated=%3d distinct=%4d time=%5.1fs",
                level.side, level.side * level.side, level.requests,
                level.saturated, level.found.count, level.seconds
            ))
        }

        // What each finer pass added that every coarser pass together had missed.
        var seen: Set<String> = []
        for level in levels {
            let novel = level.found.subtracting(seen)
            let costPerNewPark = novel.isEmpty ? Double.infinity : Double(level.requests) / Double(novel.count)
            print(String(
                format: "PROBE side=%2d new=%4d cumulative=%4d requests/new-park=%.2f",
                level.side, novel.count, seen.count + novel.count, costPerNewPark
            ))
            seen.formUnion(level.found)
        }

        let widest = levels[0].found
        let finest = levels.last!.found
        print("PROBE one wide request found \(widest.count); the finest grid found \(finest.count)")
        print("PROBE the finest grid missed \(widest.subtracting(finest).count) that the wide request had")
        print("PROBE total distinct across every pass: \(seen.count)")

        XCTAssertFalse(seen.isEmpty, "The map returned nothing at all — this measures nothing")
    }

    /// Somewhere ordinary, to see whether saturation all the way down is a city thing or
    /// simply what always happens. The split factor only matters if the two differ.
    func testSaturationSomewhereLessDense() async throws {
        let suburb = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 47.674, longitude: -122.121),
            span: MKCoordinateSpan(latitudeDelta: 0.15, longitudeDelta: 0.16)
        )

        for side in [1, 3] {
            var found: Set<String> = []
            var saturated = 0
            var requests = 0
            for tile in ParkDiscoveryService.tiles(for: suburb, side: side) {
                let (parks, raw) = await search(tile)
                requests += 1
                found.formUnion(parks.keys)
                if raw >= ParkDiscoveryService.saturatedResultCount { saturated += 1 }
            }
            print(String(
                format: "PROBE suburb side=%2d requests=%3d saturated=%3d of %3d distinct=%4d",
                side, requests, saturated, side * side, found.count
            ))
        }
    }
}
