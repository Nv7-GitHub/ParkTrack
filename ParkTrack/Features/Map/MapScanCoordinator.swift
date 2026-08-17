import Foundation
import MapKit
import Observation

/// Remembers which ground we've already asked MapKit about.
///
/// Every scan fans out into a batch of `MKLocalSearch` requests, and panning the map
/// produces camera updates by the dozen, so a naive "discover on camera change" would
/// throttle us within seconds. This debounces the trigger and then refuses any region we
/// have already covered at a comparable zoom.
@Observable
@MainActor
final class MapScanCoordinator {
    private(set) var isScanning = false

    /// Wider than this and a scan is mostly empty tiles at continental zoom.
    private static let maxScannableSpanDegrees: Double = 1.0
    /// Below this the camera is so tight that rescanning tells us nothing new.
    private static let minScannableSpanDegrees: Double = 0.002
    private static let debounce: Duration = .milliseconds(700)
    private static let memoryLimit = 60

    private var scanned: [MKCoordinateRegion] = []
    private var pending: Task<Void, Never>?

    func regionNeedsScan(_ region: MKCoordinateRegion) -> Bool {
        let span = max(region.span.latitudeDelta, region.span.longitudeDelta)
        guard span.isFinite, span <= Self.maxScannableSpanDegrees, span >= Self.minScannableSpanDegrees else {
            return false
        }
        return !scanned.contains { Self.covers($0, region) }
    }

    /// Only the region the camera finally settled on is ever scanned.
    func scheduleScan(of region: MKCoordinateRegion, run: @escaping (MKCoordinateRegion) async -> Void) {
        guard regionNeedsScan(region) else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, self.regionNeedsScan(region) else { return }

            self.isScanning = true
            await run(region)
            self.isScanning = false

            guard !Task.isCancelled else { return }
            self.scanned.append(region)
            if self.scanned.count > Self.memoryLimit {
                self.scanned.removeFirst(self.scanned.count - Self.memoryLimit)
            }
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
        isScanning = false
    }

    /// True when `candidate` sits inside `known` and isn't meaningfully wider, i.e. scanning
    /// it again would only repeat requests we've already paid for.
    private static func covers(_ known: MKCoordinateRegion, _ candidate: MKCoordinateRegion) -> Bool {
        guard candidate.span.latitudeDelta <= known.span.latitudeDelta * 1.15,
              candidate.span.longitudeDelta <= known.span.longitudeDelta * 1.15 else { return false }

        let latSlack = (known.span.latitudeDelta - candidate.span.latitudeDelta) / 2
        let lonSlack = (known.span.longitudeDelta - candidate.span.longitudeDelta) / 2
        return abs(candidate.center.latitude - known.center.latitude) <= max(latSlack, 0)
            && abs(candidate.center.longitude - known.center.longitude) <= max(lonSlack, 0)
    }
}
