import Foundation
import CoreLocation
import Observation

/// Single source of truth for "where is the user right now" and the permission state
/// around it. Only ever asks for when-in-use authorization.
@Observable
@MainActor
final class LocationProvider: NSObject {
    private let manager = CLLocationManager()

    private(set) var currentLocation: CLLocation?
    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    private(set) var isUpdating = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        // Without a distance filter Core Location republishes constantly, and because every
        // screen derives its stats from `currentLocation`, each of those ticks re-ran the
        // radius, records and recommendation passes over every cached park. Nothing in this
        // app changes meaningfully over a few metres.
        manager.distanceFilter = 25
        authorizationStatus = manager.authorizationStatus
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    func requestAuthorization() {
        guard authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    func start() {
        guard isAuthorized else {
            requestAuthorization()
            return
        }
        guard !isUpdating else { return }
        isUpdating = true
        manager.startUpdatingLocation()
    }

    func stop() {
        guard isUpdating else { return }
        isUpdating = false
        manager.stopUpdatingLocation()
    }

    /// Publishes a fix only when it actually moves the user, or genuinely improves on what
    /// we had. `distanceFilter` is a hint Core Location does not always honour, and a fix
    /// that lands two metres away is not worth invalidating every derived stat in the app.
    private func acceptIfMeaningful(_ candidate: CLLocation) {
        guard let existing = currentLocation else {
            currentLocation = candidate
            return
        }
        let moved = candidate.distance(from: existing)
        let isMuchMoreAccurate = candidate.horizontalAccuracy < existing.horizontalAccuracy / 2
        let isStale = candidate.timestamp.timeIntervalSince(existing.timestamp) > 120
        guard moved >= 25 || isMuchMoreAccurate || isStale else { return }
        currentLocation = candidate
    }

    /// Current location if we already have a recent one, otherwise waits briefly for a fix.
    func resolveLocation(timeout: Duration = .seconds(5)) async -> CLLocation? {
        if let currentLocation, Date().timeIntervalSince(currentLocation.timestamp) < 60 {
            return currentLocation
        }
        start()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let currentLocation { return currentLocation }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return currentLocation
    }
}

extension LocationProvider: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        Task { @MainActor in
            self.acceptIfMeaningful(latest)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                self.start()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A transient failure just means no fix yet; the UI already handles a nil location.
    }
}
