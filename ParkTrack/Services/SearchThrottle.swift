import Foundation
import MapKit

/// Serializes every `MKLocalSearch` in the app behind a minimum spacing, and retries when
/// Apple throttles us anyway.
///
/// This exists because a tiled area scan issues many searches back to back, and MapKit
/// responds to bursts with `MKError.loadingThrottled` — which previously meant a scan
/// returned nothing at all. Going through one actor makes the whole app's search traffic
/// a single well-behaved stream regardless of how many screens ask at once.
actor SearchThrottle {
    static let shared = SearchThrottle()

    /// Spacing between consecutive searches. Chosen empirically: fast enough that a nine-tile
    /// scan finishes in a few seconds, slow enough that MapKit doesn't start refusing.
    private static let minimumInterval: Duration = .milliseconds(320)
    private static let maxAttempts = 3

    private var nextAllowedStart: ContinuousClock.Instant = .now

    /// Runs one search, waiting its turn first and backing off if MapKit says it's busy.
    func run(_ request: MKLocalSearch.Request) async throws -> MKLocalSearch.Response {
        var attempt = 0
        while true {
            attempt += 1
            await waitForTurn()
            do {
                return try await MKLocalSearch(request: request).start()
            } catch {
                guard attempt < Self.maxAttempts, Self.isThrottled(error) else { throw error }
                // Exponential backoff on top of the regular spacing.
                let backoff = Duration.milliseconds(500 * (1 << (attempt - 1)))
                nextAllowedStart = .now.advanced(by: backoff)
            }
        }
    }

    private func waitForTurn() async {
        let now = ContinuousClock.now
        if now < nextAllowedStart {
            try? await Task.sleep(until: nextAllowedStart, clock: .continuous)
        }
        nextAllowedStart = ContinuousClock.now.advanced(by: Self.minimumInterval)
    }

    nonisolated static func isThrottled(_ error: Error) -> Bool {
        guard let mkError = error as? MKError else { return false }
        return mkError.code == .loadingThrottled || mkError.code == .serverFailure
    }
}
