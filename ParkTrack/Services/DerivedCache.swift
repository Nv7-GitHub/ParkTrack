import Foundation
import CoreLocation
import SwiftData

/// Remembers one derived value against a cheap signature of its inputs.
///
/// The stats engines cost single-digit milliseconds per call over a few hundred parks, and
/// SwiftUI evaluates a body far more often than the underlying data changes — a location
/// tick, a sheet appearing, a scroll. Recomputing on every pass put a screen over the frame
/// budget before anything was drawn. This holds the last answer and hands it straight back
/// while the signature is unchanged.
///
/// It is a reference type on purpose: views keep it in `@State`, and updating the cache must
/// not itself invalidate the view that just read from it.
@MainActor
final class DerivedCache<Value> {
    private var signature: StatsSignature?
    private var cached: Value?

    func value(for signature: StatsSignature, compute: () -> Value) -> Value {
        if let cached, self.signature == signature {
            return cached
        }
        let fresh = compute()
        self.signature = signature
        self.cached = fresh
        return fresh
    }
}

/// What every derived stat actually depends on.
///
/// Coordinates are rounded to roughly a hundred metres: GPS jitter of a few metres cannot
/// change a completion count, and treating it as a new input is what made the map stutter
/// while standing still.
struct StatsSignature: Equatable {
    let parkCount: Int
    let visitCount: Int
    let anchorLatitude: Double?
    let anchorLongitude: Double?
    let extra: [Double]

    /// A copy of this signature that also varies with a section's own control state — the
    /// selected scope, the chosen month range — so one cache can serve a segmented control.
    func adding(_ value: Double) -> StatsSignature {
        StatsSignature(
            parkCount: parkCount,
            visitCount: visitCount,
            anchorLatitude: anchorLatitude,
            anchorLongitude: anchorLongitude,
            extra: extra + [value]
        )
    }

    /// Counts supplied directly, which is how views build it: `parks.count` is free from
    /// the existing `@Query`, and the visit count comes from a `COUNT` on the store rather
    /// than by faulting every park's relationship.
    init(
        parkCount: Int,
        visitCount: Int,
        anchor: CLLocationCoordinate2D? = nil,
        extra: [Double] = []
    ) {
        self.parkCount = parkCount
        self.visitCount = visitCount
        self.anchorLatitude = anchor.map { ($0.latitude * 1_000).rounded() / 1_000 }
        self.anchorLongitude = anchor.map { ($0.longitude * 1_000).rounded() / 1_000 }
        self.extra = extra
    }

    private init(
        parkCount: Int,
        visitCount: Int,
        anchorLatitude: Double?,
        anchorLongitude: Double?,
        extra: [Double]
    ) {
        self.parkCount = parkCount
        self.visitCount = visitCount
        self.anchorLatitude = anchorLatitude
        self.anchorLongitude = anchorLongitude
        self.extra = extra
    }

    init(
        parks: [Park],
        anchor: CLLocationCoordinate2D? = nil,
        extra: [Double] = []
    ) {
        self.parkCount = parks.count
        self.visitCount = parks.reduce(0) { $0 + $1.visitCount }
        self.anchorLatitude = anchor.map { ($0.latitude * 1_000).rounded() / 1_000 }
        self.anchorLongitude = anchor.map { ($0.longitude * 1_000).rounded() / 1_000 }
        self.extra = extra
    }
}


extension ModelContext {
    /// Total logged visits, counted by the store instead of by walking relationships.
    func visitCount() -> Int {
        (try? fetchCount(FetchDescriptor<Visit>())) ?? 0
    }
}
