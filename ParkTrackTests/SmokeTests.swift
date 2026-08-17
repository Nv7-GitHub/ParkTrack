import XCTest
import CoreLocation
@testable import ParkTrack

final class ParkIdentityTests: XCTestCase {
    func testIdentityIsStableAcrossCaseAndWhitespace() {
        let a = Park.identity(name: "Robinswood Park", coordinate: .init(latitude: 47.58, longitude: -122.14))
        let b = Park.identity(name: "  robinswood park ", coordinate: .init(latitude: 47.58, longitude: -122.14))
        XCTAssertEqual(a, b)
    }

    func testIdentityDiffersForDistinctParks() {
        let a = Park.identity(name: "Riverfront Park", coordinate: .init(latitude: 47.58, longitude: -122.14))
        let b = Park.identity(name: "Riverfront Park", coordinate: .init(latitude: 41.88, longitude: -87.62))
        XCTAssertNotEqual(a, b)
    }
}
