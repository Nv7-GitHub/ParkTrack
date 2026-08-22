import XCTest
import CoreLocation
@testable import ParkTrack

/// Measures how `Park.identity` behaves around same-name parks and coordinate drift.
///
/// A probe rather than a guard: nothing here asserts a requirement the app has agreed to
/// meet. It exists to put numbers on two opposite failure modes before a design leans on
/// identity for cross-device matching — the Boston Common case (two genuinely different
/// parks sharing a name, which must stay apart) and grid drift (one park re-found a metre
/// away, which must stay together).
final class ParkIdentityProbe: XCTestCase {

    /// Boston Common, near enough.
    private let bostonLat = 42.3550
    private let bostonLon = -71.0656

    private func identity(_ name: String, _ lat: Double, _ lon: Double) -> String {
        Park.identity(name: name, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }

    private func metres(_ aLat: Double, _ aLon: Double, _ bLat: Double, _ bLon: Double) -> Double {
        CLLocation(latitude: aLat, longitude: aLon)
            .distance(from: CLLocation(latitude: bLat, longitude: bLon))
    }

    /// How far apart one grid step actually is at Boston's latitude.
    func testGridResolution() {
        let latStep = metres(bostonLat, bostonLon, bostonLat + 0.0001, bostonLon)
        let lonStep = metres(bostonLat, bostonLon, bostonLat, bostonLon + 0.0001)
        print("PROBE grid step: latitude \(String(format: "%.2f", latStep)) m, longitude \(String(format: "%.2f", lonStep)) m")
    }

    /// Two same-name parks 150 m apart: do they stay distinct?
    func testSameNameOneHundredFiftyMetresApart() {
        let offset = 0.00135 // ~150 m of latitude
        let a = identity("Boston Common", bostonLat, bostonLon)
        let b = identity("Boston Common", bostonLat + offset, bostonLon)
        let apart = metres(bostonLat, bostonLon, bostonLat + offset, bostonLon)
        print("PROBE 150 m apart (\(String(format: "%.0f", apart)) m): distinct=\(a != b)")
        print("PROBE   a=\(a)")
        print("PROBE   b=\(b)")
        XCTAssertNotEqual(a, b, "two different parks sharing a name collapsed into one identity")
    }

    /// The opposite risk: the SAME park, re-found a hand's breadth away, straddling a grid
    /// boundary. If this splits, a friend's exclusion will not match the local park.
    func testSameParkAcrossAGridBoundary() {
        let below = 42.354949
        let above = 42.354951
        let a = identity("Boston Common", below, bostonLon)
        let b = identity("Boston Common", above, bostonLon)
        let apart = metres(below, bostonLon, above, bostonLon)
        print("PROBE same park \(String(format: "%.2f", apart)) m apart: same identity=\(a == b)")
        print("PROBE   a=\(a)")
        print("PROBE   b=\(b)")
    }

    /// How much drift it takes before a split becomes likely, sampled across the grid.
    func testDriftSensitivity() {
        var splits = 0
        let samples = 1000
        for step in 0..<samples {
            // Walk a metre at a time across several grid cells.
            let base = bostonLat + Double(step) * 0.000009
            let nudged = base + 0.000009 // ~1 m further
            if identity("Boston Common", base, bostonLon) != identity("Boston Common", nudged, bostonLon) {
                splits += 1
            }
        }
        let percent = Double(splits) / Double(samples) * 100
        print("PROBE a 1 m re-find splits identity \(String(format: "%.1f", percent))% of the time (\(splits)/\(samples))")
    }
}
