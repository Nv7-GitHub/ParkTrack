import XCTest
import CoreLocation
import SwiftData
@testable import ParkTrack

@MainActor
final class RegionIndexTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        container = PersistenceController.makeInMemoryContainer()
        context = ModelContext(container)
    }

    private func makePark(
        _ name: String,
        city: String?,
        county: String? = nil,
        state: String? = "Example State",
        visited: Bool = false
    ) -> Park {
        let park = Park(identifier: name, name: name, latitude: 1, longitude: 1)
        park.locality = city
        park.subAdministrativeArea = county
        park.administrativeArea = state
        context.insert(park)
        if visited {
            let visit = Visit(park: park)
            context.insert(visit)
        }
        return park
    }

    private func makeIndex(
        kind: RegionKind,
        name: String,
        container containerName: String?,
        parkCount: Int,
        indexed: Bool = true
    ) -> RegionIndex {
        let index = RegionIndex(
            identifier: RegionIndex.identity(kind: kind, name: name, container: containerName),
            kind: kind,
            name: name,
            container: containerName,
            country: "Example Country",
            center: CLLocationCoordinate2D(latitude: 1, longitude: 1),
            radiusMeters: 8_000
        )
        index.parkCount = parkCount
        if indexed {
            index.indexedAt = Date()
            index.indexerVersion = RegionIndex.currentIndexerVersion
        }
        context.insert(index)
        return index
    }

    func testIdentityIgnoresCaseAndAccents() {
        XCTAssertEqual(
            RegionIndex.identity(kind: .city, name: "Sāmple City", container: "Example State"),
            RegionIndex.identity(kind: .city, name: "  sample city ", container: "example state")
        )
    }

    func testCityAndCountyOfTheSameNameAreDistinctIndexes() {
        XCTAssertNotEqual(
            RegionIndex.identity(kind: .city, name: "Sample", container: "Example State"),
            RegionIndex.identity(kind: .county, name: "Sample", container: "Example State")
        )
    }

    func testParkIdentityMatchesIndexIdentity() {
        let park = makePark("A", city: "Sample City", county: "Sample County")
        XCTAssertEqual(
            RegionIndex.identity(kind: .city, park: park),
            RegionIndex.identity(kind: .city, name: "Sample City", container: "Example State")
        )
        XCTAssertEqual(
            RegionIndex.identity(kind: .county, park: park),
            RegionIndex.identity(kind: .county, name: "Sample County", container: "Example State")
        )
    }

    func testUnplacedParkHasNoRegionIdentity() {
        let park = makePark("A", city: nil, state: nil)
        XCTAssertNil(RegionIndex.identity(kind: .city, park: park))
    }

    /// The bug this whole feature exists to fix: without an index the denominator is however
    /// many parks happen to have been found, so it moves when the search radius does.
    func testIndexedTotalDoesNotChangeWhenMoreParksAreDiscovered() {
        let parks = [
            makePark("A", city: "Sample City", visited: true),
            makePark("B", city: "Sample City")
        ]
        let index = makeIndex(kind: .city, name: "Sample City", container: "Example State", parkCount: 20)

        let before = StatsEngine.completionByCity(parks: parks, indexes: [index])
        XCTAssertEqual(before.first?.total, 20)
        XCTAssertEqual(before.first?.visited, 1)

        let wider = parks + [makePark("C", city: "Sample City"), makePark("D", city: "Sample City")]
        let after = StatsEngine.completionByCity(parks: wider, indexes: [index])
        XCTAssertEqual(after.first?.total, 20, "An indexed total must not move just because more parks were found")
        XCTAssertEqual(after.first?.visited, 1)
    }

    func testWithoutAnIndexTheTotalIsWhatHasBeenFound() {
        let parks = [makePark("A", city: "Sample City", visited: true), makePark("B", city: "Sample City")]
        let completion = StatsEngine.completionByCity(parks: parks).first
        XCTAssertEqual(completion?.total, 2)
        XCTAssertEqual(completion?.isIndexed, false)
    }

    func testIndexedFlagAndDateAreReported() {
        let parks = [makePark("A", city: "Sample City", visited: true)]
        let index = makeIndex(kind: .city, name: "Sample City", container: "Example State", parkCount: 9)
        let completion = StatsEngine.completionByCity(parks: parks, indexes: [index]).first
        XCTAssertEqual(completion?.isIndexed, true)
        XCTAssertNotNil(completion?.indexedAt)
        XCTAssertEqual(completion?.identifier, index.identifier)
    }

    /// A stale index that under-counts must never produce a percentage over 100.
    func testFoundParksBeatAStaleIndexCount() {
        let parks = (0..<5).map { makePark("P\($0)", city: "Sample City", visited: true) }
        let index = makeIndex(kind: .city, name: "Sample City", container: "Example State", parkCount: 2)
        let completion = StatsEngine.completionByCity(parks: parks, indexes: [index]).first
        XCTAssertEqual(completion?.total, 5)
        XCTAssertEqual(completion?.fraction, 1.0)
    }

    /// Totals from an older indexer came from a coarser sweep and cannot be compared with
    /// today's, so they must not be used until the place has been swept again.
    func testIndexFromAnOlderGenerationIsNotTrusted() {
        let parks = [makePark("A", city: "Sample City", visited: true), makePark("B", city: "Sample City")]
        let index = makeIndex(kind: .city, name: "Sample City", container: "Example State", parkCount: 40)
        index.indexerVersion = RegionIndex.currentIndexerVersion - 1

        XCTAssertFalse(index.isIndexed)
        XCTAssertTrue(index.needsReindexing, "The place is still worth indexing, it just needs re-sweeping")

        let completion = StatsEngine.completionByCity(parks: parks, indexes: [index]).first
        XCTAssertEqual(completion?.total, 2, "A stale generation's total must not be used")
        XCTAssertEqual(completion?.isIndexed, false)
    }

    func testApproximateFlagSurfacesOnTheCompletion() {
        let parks = [makePark("A", city: "Sample City", visited: true)]
        let index = makeIndex(kind: .city, name: "Sample City", container: "Example State", parkCount: 12)
        index.isApproximate = true
        let completion = StatsEngine.completionByCity(parks: parks, indexes: [index]).first
        XCTAssertEqual(completion?.isApproximate, true)
    }

    func testCompletionCarriesBothHalves() {
        let parks = [
            makePark("A", city: "Sample City", visited: true),
            makePark("B", city: "Sample City", visited: true),
            makePark("C", city: "Sample City")
        ]
        let completion = StatsEngine.completionByCity(parks: parks).first
        XCTAssertEqual(completion?.visitedParks.count, 2)
        XCTAssertEqual(completion?.remaining.count, 1)
    }

    func testAnIncompleteIndexIsIgnored() {
        let parks = [makePark("A", city: "Sample City", visited: true), makePark("B", city: "Sample City")]
        let index = makeIndex(kind: .city, name: "Sample City", container: "Example State", parkCount: 40, indexed: false)
        let completion = StatsEngine.completionByCity(parks: parks, indexes: [index]).first
        XCTAssertEqual(completion?.total, 2, "A half-swept region must not present its count as the total")
        XCTAssertEqual(completion?.isIndexed, false)
    }

    func testCountyCompletionUsesCountyIndex() {
        let parks = [
            makePark("A", city: "Sample City", county: "Sample County", visited: true),
            makePark("B", city: "Other City", county: "Sample County")
        ]
        let index = makeIndex(kind: .county, name: "Sample County", container: "Example State", parkCount: 30)
        let completion = StatsEngine.completionByCounty(parks: parks, indexes: [index]).first
        XCTAssertEqual(completion?.name, "Sample County")
        XCTAssertEqual(completion?.total, 30)
        XCTAssertEqual(completion?.visited, 1)
    }

    func testParkAdoptsRegionFromSearchResultWithoutGeocoding() {
        let park = Park(identifier: "x", name: "Sample Park", latitude: 1, longitude: 1)
        let candidate = ParkCandidate(
            id: "x",
            name: "Sample Park",
            coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 1),
            category: nil,
            addressLine: nil,
            locality: "Sample City",
            subAdministrativeArea: "Sample County",
            administrativeArea: "Example State",
            country: "Example Country"
        )
        park.apply(candidate)
        XCTAssertEqual(park.locality, "Sample City")
        XCTAssertEqual(park.subAdministrativeArea, "Sample County")
        XCTAssertNotNil(park.regionResolvedAt, "A placed result should not need the geocoder")
    }

    func testParkWithoutALocalityStillNeedsGeocoding() {
        let park = Park(identifier: "x", name: "Sample Park", latitude: 1, longitude: 1)
        park.apply(ParkCandidate(
            id: "x",
            name: "Sample Park",
            coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 1),
            category: nil,
            addressLine: nil,
            locality: nil,
            subAdministrativeArea: nil,
            administrativeArea: nil,
            country: "Example Country"
        ))
        XCTAssertNil(park.regionResolvedAt)
    }
}

/// The cheap half of region resolution: adopting a city from neighbours that already know
/// theirs, so the rate-limited geocoder is only spent on genuinely unknown parks.
@MainActor
final class NeighbourRegionInferenceTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        container = PersistenceController.makeInMemoryContainer()
        context = ModelContext(container)
    }

    private func park(_ name: String, lat: Double, lon: Double, city: String? = nil) -> Park {
        let park = Park(identifier: name, name: name, latitude: lat, longitude: lon)
        park.locality = city
        park.subAdministrativeArea = city == nil ? nil : "Sample County"
        park.administrativeArea = city == nil ? nil : "Example State"
        context.insert(park)
        return park
    }

    func testAdoptsCityFromAgreeingNeighbours() {
        let placed = [
            park("A", lat: 47.6000, lon: -122.2000, city: "Sample City"),
            park("B", lat: 47.6010, lon: -122.2010, city: "Sample City")
        ]
        let unplaced = park("C", lat: 47.6005, lon: -122.2005)

        XCTAssertTrue(RegionResolver.adoptRegion(for: unplaced, from: placed))
        XCTAssertEqual(unplaced.locality, "Sample City")
        XCTAssertEqual(unplaced.subAdministrativeArea, "Sample County")
        XCTAssertNotNil(unplaced.regionResolvedAt)
    }

    /// Near a boundary the neighbours disagree, and guessing would file the park under the
    /// wrong city and corrupt that city's completion count.
    func testRefusesToGuessWhenNeighboursDisagree() {
        let placed = [
            park("A", lat: 47.6000, lon: -122.2000, city: "Sample City"),
            park("B", lat: 47.6010, lon: -122.2010, city: "Other City")
        ]
        let unplaced = park("C", lat: 47.6005, lon: -122.2005)

        XCTAssertFalse(RegionResolver.adoptRegion(for: unplaced, from: placed))
        XCTAssertNil(unplaced.locality)
        XCTAssertNil(unplaced.regionResolvedAt)
    }

    func testIgnoresNeighboursThatAreTooFarAway() {
        let placed = [park("A", lat: 47.7000, lon: -122.4000, city: "Sample City")]
        let unplaced = park("C", lat: 47.6000, lon: -122.2000)

        XCTAssertFalse(RegionResolver.adoptRegion(for: unplaced, from: placed))
        XCTAssertNil(unplaced.locality)
    }

    func testNoNeighboursAtAllIsNotAnAdoption() {
        let unplaced = park("C", lat: 47.6000, lon: -122.2000)
        XCTAssertFalse(RegionResolver.adoptRegion(for: unplaced, from: []))
    }
}

/// How much of a swept cluster gets placed without touching the geocoder. The geocoder is
/// rate-limited to roughly a request a second, so the answer decides whether placing a
/// city's worth of parks takes moments or minutes.
@MainActor
final class RegionResolutionCostTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        container = PersistenceController.makeInMemoryContainer()
        context = ModelContext(container)
    }

    func testNeighbourInferencePlacesTheBulkOfACluster() throws {
        // A realistic shape: a cluster where the map named some parks and not others.
        var placed: [Park] = []
        var unplaced: [Park] = []
        for index in 0..<60 {
            let park = Park(
                identifier: "p\(index)",
                name: "Park \(index)",
                latitude: 47.60 + Double(index % 10) * 0.002,
                longitude: -122.20 + Double(index / 10) * 0.002
            )
            context.insert(park)
            if index % 2 == 0 {
                park.locality = "Sample City"
                park.subAdministrativeArea = "Sample County"
                park.administrativeArea = "Example State"
                park.regionResolvedAt = Date()
                placed.append(park)
            } else {
                unplaced.append(park)
            }
        }

        let adopted = unplaced.count { RegionResolver.adoptRegion(for: $0, from: placed) }
        XCTAssertEqual(adopted, unplaced.count, "Every park inside an agreeing cluster should be placed without the geocoder")
        XCTAssertTrue(unplaced.allSatisfy { $0.locality == "Sample City" })
    }
}
