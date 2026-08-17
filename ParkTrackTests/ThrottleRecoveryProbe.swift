import XCTest
import MapKit
@testable import ParkTrack

/// How long the map service stays unhappy once it starts refusing.
///
/// Apple documents neither the rate nor the recovery window, and the answer decides what the
/// app should tell someone staring at "the map service is busy". This drives it into the
/// limit deliberately, then polls with a plain request until one succeeds.
final class ThrottleRecoveryProbe: XCTestCase {
    private func rawSearch() async -> Bool {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "park"
        request.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 47.6101, longitude: -122.2015),
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )
        do {
            _ = try await MKLocalSearch(request: request).start()
            return true
        } catch {
            return false
        }
    }

    func testHowLongThrottlingLasts() async throws {
        // Push until it refuses.
        var refusedAfter = 0
        for index in 1...120 {
            if await rawSearch() == false {
                refusedAfter = index
                break
            }
        }
        guard refusedAfter > 0 else {
            print("PROBE never throttled within 120 back-to-back requests")
            return
        }
        print("PROBE throttled after \(refusedAfter) back-to-back requests")

        let start = Date()
        for _ in 0..<10 {
            try? await Task.sleep(for: .seconds(10))
            if await rawSearch() {
                print("PROBE recovered after \(Int(Date().timeIntervalSince(start)))s")
                return
            }
        }
        print("PROBE still refused after \(Int(Date().timeIntervalSince(start)))s")
    }
}
