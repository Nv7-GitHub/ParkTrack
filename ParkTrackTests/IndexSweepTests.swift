import XCTest
import CoreLocation
import MapKit
import SwiftData
@testable import ParkTrack

/// Drives the real `sweepDense` traversal over a synthetic city, so what indexing a place
/// costs — and whether it can ever call itself finished — is measurable without spending a
/// single request against the map service.
@MainActor
final class IndexSweepTests: XCTestCase {

    /// Sammamish's own numbers, from geocoding it: a city of about twenty parks, sitting in
    /// a circle the geocoder draws 7.7 km across.
    private let centre = CLLocationCoordinate2D(latitude: 47.6017576, longitude: -122.0356084)
    private let radiusMeters: CLLocationDistance = 7662.4
    private var radiusMiles: Double { radiusMeters / Format.metersPerMile }

    private var container: ModelContainer!
    private var context: ModelContext!
    private var service: ParkDiscoveryService!

    override func setUp() {
        super.setUp()
        container = PersistenceController.makeInMemoryContainer()
        context = ModelContext(container)
        service = ParkDiscoveryService(modelContext: context)
    }

    /// Parks on a grid across the ground a city occupies.
    private func city(
        southWest: CLLocationCoordinate2D,
        northEast: CLLocationCoordinate2D,
        parks parkCount: Int
    ) -> [(coordinate: CLLocationCoordinate2D, name: String)] {
        let side = Int(Double(parkCount).squareRoot().rounded(.up))
        var parks: [(CLLocationCoordinate2D, String)] = []
        for row in 0..<side {
            for column in 0..<side where parks.count < parkCount {
                let latitude = southWest.latitude
                    + (Double(row) + 0.5) / Double(side) * (northEast.latitude - southWest.latitude)
                let longitude = southWest.longitude
                    + (Double(column) + 0.5) / Double(side) * (northEast.longitude - southWest.longitude)
                parks.append((CLLocationCoordinate2D(latitude: latitude, longitude: longitude), "Park \(row)-\(column)"))
            }
        }
        return parks
    }

    private var sammamish: [(coordinate: CLLocationCoordinate2D, name: String)] {
        city(
            southWest: CLLocationCoordinate2D(latitude: 47.575, longitude: -122.055),
            northEast: CLLocationCoordinate2D(latitude: 47.650, longitude: -121.995),
            parks: 20
        )
    }

    /// A map that answers about the cell it was asked about, as the bounded request does.
    private func answering(
        _ parks: [(coordinate: CLLocationCoordinate2D, name: String)],
        locality: String,
        counting cells: CellCounter
    ) -> @Sendable (MKCoordinateRegion) async -> ParkDiscoveryService.TileOutcome {
        { cell in
            await cells.bump()
            var outcome = ParkDiscoveryService.TileOutcome()
            for park in parks where SweptCoverage.region(cell, contains: park.coordinate) {
                outcome.candidates.append(ParkCandidate(
                    id: Park.identity(name: park.name, coordinate: park.coordinate),
                    name: park.name,
                    coordinate: park.coordinate,
                    category: MKPointOfInterestCategory.park.rawValue,
                    isParkLike: true,
                    locality: locality
                ))
            }
            outcome.rawCount = outcome.candidates.count
            return outcome
        }
    }

    func testACityIsSweptInsideItsBudgetAndFindsEveryParkInIt() async {
        let parks = sammamish
        let cells = CellCounter()
        let result = await service.sweepDense(
            around: centre,
            radiusMiles: radiusMiles,
            belongsToRegion: { $0.locality == "Sammamish" },
            searchCell: answering(parks, locality: "Sammamish", counting: cells)
        )

        let searched = await cells.value
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.found.count, parks.count, "a city's own parks were missed")
        XCTAssertLessThan(searched, ParkDiscoveryService.maxIndexSearches,
                          "a city of twenty parks spent its whole budget")
    }

    /// The Kirkland bug, at the place it was made. Every cell of a populated area came back
    /// "full", because the search answered with about twenty-five parks wherever it was
    /// pointed — so every index was marked "at least this many" for ever, and re-indexing
    /// could not clear it, the number having nothing to do with the cell.
    ///
    /// These are the twenty-five results one cell of Kirkland really returned, with the two
    /// that were in it.
    func testSaturationCountsOnlyWhatWasInTheCell() {
        let cell = ParkDiscoveryService.latticeCell(
            containing: CLLocationCoordinate2D(latitude: 47.6769, longitude: -122.2060)
        )
        let inCell = [
            CLLocationCoordinate2D(latitude: cell.center.latitude, longitude: cell.center.longitude),
            CLLocationCoordinate2D(
                latitude: cell.center.latitude + cell.span.latitudeDelta / 4,
                longitude: cell.center.longitude - cell.span.longitudeDelta / 4
            )
        ]
        // Bellevue, Medina, Mercer Island: real answers to a question about Kirkland.
        let elsewhere = (0..<23).map { index in
            CLLocationCoordinate2D(latitude: 47.61 - Double(index) * 0.002, longitude: -122.20)
        }

        XCTAssertEqual(ParkDiscoveryService.resultsInside(cell, coordinates: inCell + elsewhere), 2)
        XCTAssertLessThan(
            ParkDiscoveryService.resultsInside(cell, coordinates: inCell + elsewhere),
            ParkDiscoveryService.saturatedResultCount,
            "a response full of parks from elsewhere still reads as a saturated cell"
        )
    }

    /// And the case the flag is actually for: one cell really is packed with parks.
    func testACellPackedWithItsOwnParksStillReportsAFloor() async {
        let cells = CellCounter()
        let parks = sammamish
        let honest = answering(parks, locality: "Sammamish", counting: cells)
        let result = await service.sweepDense(
            around: centre,
            radiusMiles: radiusMiles,
            belongsToRegion: { $0.locality == "Sammamish" },
            searchCell: { cell in
                var outcome = await honest(cell)
                if !outcome.candidates.isEmpty {
                    outcome.rawCount = ParkDiscoveryService.saturatedResultCount
                }
                return outcome
            }
        )
        XCTAssertTrue(result.truncated)
    }

    /// The other half of the Sammamish bug. A residential plateau has streets of housing
    /// between one park and the next, and a wall rule counted in cells got tighter every
    /// time the cells got smaller — so the sweep indexed the southern half of the city and
    /// stopped at the gap before the northern one.
    func testASweepCrossesACityWhoseParksAreFarApart() async {
        // Twelve parks spread over 8 km of city: about two kilometres between neighbours.
        let sparse = city(
            southWest: CLLocationCoordinate2D(latitude: 47.575, longitude: -122.055),
            northEast: CLLocationCoordinate2D(latitude: 47.650, longitude: -121.995),
            parks: 12
        )
        let cells = CellCounter()
        let result = await service.sweepDense(
            around: centre,
            radiusMiles: radiusMiles,
            belongsToRegion: { $0.locality == "Sammamish" },
            searchCell: answering(sparse, locality: "Sammamish", counting: cells)
        )

        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.found.count, sparse.count, "the far side of the city was walled off")
    }

    /// And it still stops when the parks it is finding belong to the next town along, which
    /// is different evidence from finding nothing.
    func testASweepStopsWhereTheNextTownStarts() async {
        let ours = city(
            southWest: CLLocationCoordinate2D(latitude: 47.595, longitude: -122.045),
            northEast: CLLocationCoordinate2D(latitude: 47.612, longitude: -122.025),
            parks: 6
        )
        // Everywhere else inside the circle is thick with somebody else's parks.
        let cells = CellCounter()
        let mine = answering(ours, locality: "Sammamish", counting: cells)
        let result = await service.sweepDense(
            around: centre,
            radiusMiles: radiusMiles,
            belongsToRegion: { $0.locality == "Sammamish" },
            searchCell: { cell in
                var outcome = await mine(cell)
                guard outcome.candidates.isEmpty else { return outcome }
                outcome.candidates = [ParkCandidate(
                    id: Park.identity(name: "Redmond \(ParkDiscoveryService.latticeKey(cell))", coordinate: cell.center),
                    name: "Redmond \(ParkDiscoveryService.latticeKey(cell))",
                    coordinate: cell.center,
                    category: MKPointOfInterestCategory.park.rawValue,
                    isParkLike: true,
                    locality: "Redmond"
                )]
                outcome.rawCount = 1
                return outcome
            }
        )
        let searched = await cells.value
        XCTAssertTrue(result.completed)
        // The circle holds roughly three hundred cells; a town's skirt is a fraction of it.
        XCTAssertLessThan(searched, 120, "the sweep kept going into the town next door")
    }

    /// Re-indexing skips ground already searched this way, so it is not a second full price.
    func testReIndexingReusesGroundAlreadySwept() async {
        let parks = sammamish
        let first = CellCounter()
        _ = await service.sweepDense(
            around: centre,
            radiusMiles: radiusMiles,
            belongsToRegion: { $0.locality == "Sammamish" },
            searchCell: answering(parks, locality: "Sammamish", counting: first)
        )
        let firstCount = await first.value
        XCTAssertGreaterThan(firstCount, 0)

        let second = CellCounter()
        let result = await service.sweepDense(
            around: centre,
            radiusMiles: radiusMiles,
            belongsToRegion: { $0.locality == "Sammamish" },
            searchCell: answering(parks, locality: "Sammamish", counting: second)
        )
        let secondCount = await second.value
        XCTAssertTrue(result.completed)
        XCTAssertLessThan(secondCount, firstCount / 4, "re-indexing re-searched ground it had already covered")
    }

    /// A cell the map kept refusing is ground nobody looked at, so the count is a floor.
    func testCellsTheMapRefusedMakeTheTotalAFloor() async {
        let parks = sammamish
        let cells = CellCounter()
        let honest = answering(parks, locality: "Sammamish", counting: cells)
        let refusals = CellCounter()
        let refusedCell = ParkDiscoveryService.latticeKey(
            ParkDiscoveryService.latticeCell(containing: parks[3].coordinate)
        )
        let result = await service.sweepDense(
            around: centre,
            radiusMiles: radiusMiles,
            belongsToRegion: { $0.locality == "Sammamish" },
            searchCell: { cell in
                let outcome = await honest(cell)
                // One cell is refused every time it is asked. Just the one, so the sweep
                // keeps making progress around it and the backoff between retries stays
                // short — a whole corner of refusals makes this test a minute long.
                guard ParkDiscoveryService.latticeKey(cell) == refusedCell else { return outcome }
                await refusals.bump()
                var refused = ParkDiscoveryService.TileOutcome()
                refused.failure = "The map service is busy."
                return refused
            }
        )
        let refused = await refusals.value
        XCTAssertGreaterThan(refused, 0, "the test never exercised a refusal")
        XCTAssertTrue(result.truncated, "a sweep that gave up on cells called its total exhaustive")
    }

    /// A place whose cells the map cannot answer about is a failure to report, not a city
    /// with no parks — and the sweep must stop rather than grind through its whole budget.
    func testASweepThatFindsNothingGivesUpWellInsideItsBudget() async {
        let cells = CellCounter()
        let result = await service.sweepDense(
            around: centre,
            radiusMiles: radiusMiles,
            belongsToRegion: { $0.locality == "Sammamish" },
            searchCell: { _ in
                await cells.bump()
                return ParkDiscoveryService.TileOutcome()
            }
        )
        let searched = await cells.value
        XCTAssertFalse(result.completed)
        XCTAssertLessThanOrEqual(searched, ParkDiscoveryService.maxIndexSearches / 2 + 1)
    }
}

/// Counts cells across the task group a sweep runs them in.
actor CellCounter {
    private(set) var value = 0
    func bump() { value += 1 }
}
