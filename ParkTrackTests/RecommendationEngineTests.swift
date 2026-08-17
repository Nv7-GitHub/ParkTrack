import XCTest
import CoreLocation
import SwiftData
@testable import ParkTrack

@MainActor
final class RecommendationEngineTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    /// All fixtures are built as offsets from an arbitrary anchor so the tests carry no
    /// real-world place in them, matching the app's region-agnostic rule.
    private let base = CLLocationCoordinate2D(latitude: 10, longitude: 20)
    private let radii: [Double] = [2.5, 5, 10]

    override func setUp() async throws {
        container = PersistenceController.makeInMemoryContainer()
        context = ModelContext(container)
    }

    override func tearDown() async throws {
        context = nil
        container = nil
    }

    // MARK: - Fixtures

    private func coordinate(milesNorth: Double, milesEast: Double = 0) -> CLLocationCoordinate2D {
        let metersPerDegreeLat = 111_320.0
        let lat = base.latitude + (milesNorth * Format.metersPerMile) / metersPerDegreeLat
        let lonScale = metersPerDegreeLat * cos(base.latitude * .pi / 180)
        let lon = base.longitude + (milesEast * Format.metersPerMile) / lonScale
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    @discardableResult
    private func makePark(
        _ name: String,
        at coordinate: CLLocationCoordinate2D,
        visits: Int = 0,
        wishlisted: Bool = false,
        locality: String? = nil
    ) -> Park {
        let park = Park(
            identifier: Park.identity(name: name, coordinate: coordinate),
            name: name,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        park.isWishlisted = wishlisted
        park.locality = locality
        context.insert(park)
        for index in 0..<visits {
            let visit = Visit(date: Date().addingTimeInterval(-Double(index) * 86_400), park: park)
            context.insert(visit)
        }
        return park
    }

    private func allParks() throws -> [Park] {
        try context.fetch(FetchDescriptor<Park>())
    }

    // MARK: - Tests

    func testWishlistOutranksEqualDistanceNonWishlist() throws {
        makePark("Saved Park", at: coordinate(milesNorth: 0, milesEast: 2), wishlisted: true)
        makePark("Other Park", at: coordinate(milesNorth: 0, milesEast: -2))

        let results = RecommendationEngine.recommendations(
            parks: try allParks(),
            origin: CLLocation(latitude: base.latitude, longitude: base.longitude),
            home: base,
            radiiMiles: radii,
            limit: 10
        )

        XCTAssertEqual(results.first?.park.name, "Saved Park")
        XCTAssertEqual(results.first?.reason, .wishlist)
        XCTAssertGreaterThan(results[0].score, results[1].score)
    }

    func testRingCompletionOutranksMarginallyCloserPark() throws {
        for index in 0..<8 {
            makePark("Logged \(index)", at: coordinate(milesNorth: 1, milesEast: Double(index) * 0.1), visits: 1)
        }
        makePark("Ring Finisher", at: coordinate(milesNorth: 4.8))
        makePark("Nearby Outlier", at: coordinate(milesNorth: 29))

        // The user is away from home, so the outlier is nearer to them but outside every ring.
        let away = coordinate(milesNorth: 30)
        let results = RecommendationEngine.recommendations(
            parks: try allParks(),
            origin: CLLocation(latitude: away.latitude, longitude: away.longitude),
            home: base,
            radiiMiles: radii,
            limit: 10
        )

        XCTAssertEqual(results.first?.park.name, "Ring Finisher")
        XCTAssertEqual(results.first?.reason, .finishRadius)
        // The headline names the ring it would finish, e.g. "1 left within 5 mi".
        XCTAssertTrue(results.first?.headline.contains("within") == true, "Got: \(results.first?.headline ?? "nil")")
    }

    func testVisitedParksAreNeverRecommended() throws {
        makePark("Visited One", at: coordinate(milesNorth: 0.5), visits: 3, wishlisted: true, locality: "Alpha")
        makePark("Visited Two", at: coordinate(milesNorth: 1), visits: 1, locality: "Alpha")
        makePark("Fresh", at: coordinate(milesNorth: 1.5), locality: "Alpha")

        let results = RecommendationEngine.recommendations(
            parks: try allParks(),
            origin: CLLocation(latitude: base.latitude, longitude: base.longitude),
            home: base,
            radiiMiles: radii,
            limit: 10
        )

        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { !$0.park.isVisited })
    }

    func testDedupKeepsHighestScoringReason() throws {
        makePark("Everything Park", at: coordinate(milesNorth: 0.4), wishlisted: true, locality: "Beta")
        makePark("Anchor Park", at: coordinate(milesNorth: 0.6), visits: 2, locality: "Beta")

        let results = RecommendationEngine.recommendations(
            parks: try allParks(),
            origin: CLLocation(latitude: base.latitude, longitude: base.longitude),
            home: base,
            radiiMiles: radii,
            limit: 10
        )

        let rows = results.filter { $0.park.name == "Everything Park" }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.reason, .wishlist)
        XCTAssertEqual(Set(results.map(\.park.identifier)).count, results.count)
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertTrue(RecommendationEngine.recommendations(
            parks: [],
            origin: CLLocation(latitude: base.latitude, longitude: base.longitude),
            home: base,
            radiiMiles: radii,
            limit: 5
        ).isEmpty)
    }

    func testAllVisitedReturnsEmpty() throws {
        makePark("Done", at: coordinate(milesNorth: 1), visits: 1)

        XCTAssertTrue(RecommendationEngine.recommendations(
            parks: try allParks(),
            origin: nil,
            home: nil,
            radiiMiles: radii,
            limit: 5
        ).isEmpty)
    }

    func testNilOriginStillReturnsResults() throws {
        makePark("Logged", at: coordinate(milesNorth: 1), visits: 1, locality: "Gamma")
        makePark("Open One", at: coordinate(milesNorth: 2), locality: "Gamma")
        makePark("Open Two", at: coordinate(milesNorth: 3), locality: "Delta")

        let results = RecommendationEngine.recommendations(
            parks: try allParks(),
            origin: nil,
            home: nil,
            radiiMiles: radii,
            limit: 5
        )

        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { !$0.park.isVisited })
        XCTAssertTrue(results.allSatisfy { $0.distanceMeters != nil })
    }

    func testNoLocationSignalAtAllStillRecommends() throws {
        makePark("Wished", at: coordinate(milesNorth: 2), wishlisted: true)

        let results = RecommendationEngine.recommendations(
            parks: try allParks(),
            origin: nil,
            home: nil,
            radiiMiles: radii,
            limit: 5
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.reason, .wishlist)
        XCTAssertNil(results.first?.distanceMeters)
    }

    func testLimitIsRespectedAndScoresDescend() throws {
        for index in 0..<12 {
            makePark("Park \(index)", at: coordinate(milesNorth: Double(index) + 0.5))
        }

        let results = RecommendationEngine.recommendations(
            parks: try allParks(),
            origin: CLLocation(latitude: base.latitude, longitude: base.longitude),
            home: base,
            radiiMiles: radii,
            limit: 4
        )

        XCTAssertEqual(results.count, 4)
        XCTAssertEqual(results.map(\.score), results.map(\.score).sorted(by: >))
    }

    func testNewTerritoryPrefersUnexploredLocality() throws {
        makePark("Home Turf", at: coordinate(milesNorth: 0.5), visits: 2, locality: "Gamma")
        makePark("Same Turf", at: coordinate(milesNorth: 0.6), locality: "Gamma")
        makePark("Fresh Turf", at: coordinate(milesNorth: 0.7), locality: "Delta")

        let results = RecommendationEngine.recommendations(
            parks: try allParks(),
            origin: CLLocation(latitude: base.latitude, longitude: base.longitude),
            home: base,
            radiiMiles: radii,
            limit: 5
        )

        let fresh = try XCTUnwrap(results.first { $0.park.name == "Fresh Turf" })
        XCTAssertEqual(fresh.reason, .newTerritory)
        XCTAssertTrue(fresh.detail.contains("Delta"))
    }
}

/// The list has to answer "how do I finish what I've started", not just "where haven't you
/// been". A user partway through several places was seeing nothing but new territory.
@MainActor
final class RecommendationVarietyTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        container = PersistenceController.makeInMemoryContainer()
        context = ModelContext(container)
    }

    private func park(_ name: String, city: String, lat: Double, lon: Double, visited: Bool) -> Park {
        let park = Park(identifier: name, name: name, latitude: lat, longitude: lon)
        park.locality = city
        park.administrativeArea = "Example State"
        context.insert(park)
        if visited { context.insert(Visit(park: park)) }
        return park
    }

    /// A city barely started still deserves finishing suggestions — this is the case the old
    /// "half done or five left" gate silently dropped.
    func testPartlyStartedRegionStillProducesFinishingAdvice() {
        var parks: [Park] = []
        for index in 0..<20 {
            parks.append(park(
                "Home \(index)",
                city: "Sample City",
                lat: 47.60 + Double(index) * 0.001,
                lon: -122.20,
                visited: index < 3
            ))
        }
        let origin = CLLocation(latitude: 47.60, longitude: -122.20)
        let results = RecommendationEngine.recommendations(
            parks: parks, origin: origin, home: origin.coordinate,
            radiiMiles: [2.5, 5, 10], limit: 8
        )
        XCTAssertTrue(
            results.contains { $0.reason == .finishRegion || $0.reason == .finishRadius },
            "Expected finishing suggestions, got: \(Set(results.map(\.reason.rawValue)).sorted())"
        )
    }

    func testNoSingleReasonFillsTheList() {
        var parks: [Park] = []
        for index in 0..<40 {
            parks.append(park(
                "City\(index % 8) Park \(index)",
                city: "City \(index % 8)",
                lat: 47.60 + Double(index) * 0.004,
                lon: -122.20 + Double(index) * 0.004,
                visited: index % 8 == 0
            ))
        }
        let origin = CLLocation(latitude: 47.60, longitude: -122.20)
        let results = RecommendationEngine.recommendations(
            parks: parks, origin: origin, home: origin.coordinate,
            radiiMiles: [2.5, 5, 10], limit: 10
        )
        let counts = Dictionary(grouping: results, by: \.reason).mapValues(\.count)
        XCTAssertGreaterThanOrEqual(Set(results.map(\.reason)).count, 3, "Expected a mix of reasons, got \(counts)")
        for (reason, count) in counts {
            XCTAssertLessThanOrEqual(count, 6, "\(reason) dominated the list: \(counts)")
        }
    }
}
