import XCTest
import CoreLocation
import MapKit
import SwiftData
@testable import ParkTrack

/// Measures the work the map and home screens repeat on every body evaluation, so the
/// cost of a re-render is a number rather than a hunch.
@MainActor
final class PerformanceProbeTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var parks: [Park] = []

    override func setUp() async throws {
        container = PersistenceController.makeInMemoryContainer()
        context = ModelContext(container)
        parks = []
        for index in 0..<400 {
            let park = Park(
                identifier: "p\(index)",
                name: "Park \(index)",
                latitude: 47.6 + Double(index % 20) * 0.01,
                longitude: -122.2 + Double(index / 20) * 0.01
            )
            context.insert(park)
            if index % 3 == 0 {
                for visitIndex in 0..<3 {
                    let visit = Visit(date: .now.addingTimeInterval(-Double(visitIndex) * 86_400), park: park)
                    context.insert(visit)
                }
            }
            parks.append(park)
        }
        try context.save()
    }

    /// The signature is built on every body pass, so it must not itself scale with the
    /// catalogue. This is the check that it stays cheap as parks accumulate.
    func testSignatureCostViaRelationshipWalk() {
        measure {
            for _ in 0..<20 {
                _ = StatsSignature(parks: parks)
            }
        }
    }

    func testSignatureCostViaFetchCount() {
        measure {
            for _ in 0..<20 {
                _ = StatsSignature(parkCount: parks.count, visitCount: context.visitCount())
            }
        }
    }

    func testIsVisitedScanCost() {
        measure {
            for _ in 0..<20 {
                _ = parks.filter(\.isVisited).count
            }
        }
    }

    func testRecordsCost() {
        let origin = CLLocation(latitude: 47.6, longitude: -122.2)
        measure {
            for _ in 0..<20 {
                _ = StatsEngine.records(parks: parks, origin: origin)
            }
        }
    }

    func testRadiusCompletionsCost() {
        let center = CLLocationCoordinate2D(latitude: 47.6, longitude: -122.2)
        measure {
            for _ in 0..<20 {
                _ = StatsEngine.radiusCompletions(parks: parks, center: center, radiiMiles: [2.5, 5, 10, 25])
            }
        }
    }

    /// The shape a real screen now has: one cold compute, then repeated reads while nothing
    /// the stats depend on has changed. This is what a body evaluation costs after caching.
    func testCachedRepeatReadsAreFree() {
        let center = CLLocationCoordinate2D(latitude: 47.6, longitude: -122.2)
        let origin = CLLocation(latitude: 47.6, longitude: -122.2)
        let recordsCache = DerivedCache<Records>()
        let completionsCache = DerivedCache<[RadiusCompletion]>()
        measure {
            for _ in 0..<20 {
                let signature = StatsSignature(parks: parks, anchor: center, extra: [2.5, 5, 10, 25])
                _ = recordsCache.value(for: signature) {
                    StatsEngine.records(parks: parks, origin: origin)
                }
                _ = completionsCache.value(for: signature) {
                    StatsEngine.radiusCompletions(parks: parks, center: center, radiiMiles: [2.5, 5, 10, 25])
                }
            }
        }
    }

    func testRecommendationsCost() {
        let origin = CLLocation(latitude: 47.6, longitude: -122.2)
        measure {
            for _ in 0..<20 {
                _ = RecommendationEngine.recommendations(
                    parks: parks, origin: origin, home: origin.coordinate,
                    radiiMiles: [2.5, 5, 10, 25], limit: 10
                )
            }
        }
    }
}

/// The zoom-dependent annotation ceiling. Panning while zoomed out was drawing hundreds of
/// pins, each a real view; these bounds are what keep a wide camera cheap.
final class AnnotationBudgetTests: XCTestCase {
    private func limit(_ delta: Double) -> Int {
        MapScreen.annotationLimit(forSpan: MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: delta))
    }

    func testCeilingFallsAsTheCameraPullsBack() {
        XCTAssertGreaterThan(limit(0.02), limit(0.2))
        XCTAssertGreaterThan(limit(0.2), limit(0.8))
        XCTAssertGreaterThan(limit(0.8), limit(5))
    }

    func testNeighbourhoodZoomStillShowsPlenty() {
        XCTAssertGreaterThanOrEqual(limit(0.02), 300)
    }

    func testWideZoomIsHeavilyCapped() {
        XCTAssertLessThanOrEqual(limit(5), 30)
    }

    func testUnknownSpanIsConservative() {
        XCTAssertLessThanOrEqual(MapScreen.annotationLimit(forSpan: nil), 100)
    }
}
