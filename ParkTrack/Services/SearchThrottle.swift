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

    /// Starting spacing between searches. Fine for the short bursts a map pan produces.
    private static let baseInterval: Duration = .milliseconds(320)
    /// Ceiling for the adaptive spacing. Indexing a county is hundreds of requests and the
    /// map service will not take them quickly however politely we ask.
    private static let maxInterval: Duration = .milliseconds(2_500)
    private static let maxAttempts = 5

    private var nextAllowedStart: ContinuousClock.Instant = .now
    /// Current spacing, which rises when the service pushes back and eases off once it stops.
    ///
    /// A fixed rate cannot be right for both cases: quick enough for a handful of searches is
    /// too quick to sustain for hundreds, and slow enough to sustain makes every ordinary map
    /// pan sluggish. So it self-tunes — a refusal widens the gap, a run of successes narrows
    /// it again.
    private var interval: Duration = baseInterval
    private var consecutiveSuccesses = 0

    /// Runs one search, waiting its turn first and backing off if MapKit says it's busy.
    func run(_ request: MKLocalSearch.Request) async throws -> MKLocalSearch.Response {
        var attempt = 0
        while true {
            attempt += 1
            await waitForTurn()
            do {
                let response = try await MKLocalSearch(request: request).start()
                noteSuccess()
                return response
            } catch {
                guard Self.isThrottled(error) else { throw error }
                noteThrottled()
                guard attempt < Self.maxAttempts else { throw error }
                // Wait out the refusal before trying the same request again. Each attempt
                // waits longer than the last.
                nextAllowedStart = .now.advanced(by: .milliseconds(800 * (1 << (attempt - 1))))
            }
        }
    }

    private func noteSuccess() {
        consecutiveSuccesses += 1
        // Ease back down only after the service has been comfortable for a while, so one
        // lucky response doesn't undo the backoff.
        if consecutiveSuccesses >= 12, interval > Self.baseInterval {
            interval = max(Self.baseInterval, interval - .milliseconds(200))
            consecutiveSuccesses = 0
        }
    }

    private func noteThrottled() {
        consecutiveSuccesses = 0
        interval = min(Self.maxInterval, interval + .milliseconds(400))
    }

    private func waitForTurn() async {
        let now = ContinuousClock.now
        if now < nextAllowedStart {
            try? await Task.sleep(until: nextAllowedStart, clock: .continuous)
        }
        nextAllowedStart = ContinuousClock.now.advanced(by: interval)
    }

    nonisolated static func isThrottled(_ error: Error) -> Bool {
        guard let mkError = error as? MKError else { return false }
        return mkError.code == .loadingThrottled || mkError.code == .serverFailure
    }
}
