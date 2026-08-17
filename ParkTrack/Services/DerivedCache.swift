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
struct StatsSignature: Equatable, Hashable {
    let parkCount: Int
    let visitCount: Int
    let anchorLatitude: Double?
    let anchorLongitude: Double?
    let extra: [Double]
    /// Control state that isn't a number — a chosen segment, a search string, a filter.
    let tokens: [String]

    /// A copy of this signature that also varies with a section's own control state — the
    /// selected scope, the chosen month range — so one cache can serve a segmented control.
    func adding(_ value: Double) -> StatsSignature {
        StatsSignature(
            parkCount: parkCount,
            visitCount: visitCount,
            anchorLatitude: anchorLatitude,
            anchorLongitude: anchorLongitude,
            extra: extra + [value],
            tokens: tokens
        )
    }

    /// Counts supplied directly, which is how views build it: `parks.count` is free from
    /// the existing `@Query`, and the visit count comes from a `COUNT` on the store rather
    /// than by faulting every park's relationship.
    init(
        parkCount: Int,
        visitCount: Int,
        anchor: CLLocationCoordinate2D? = nil,
        extra: [Double] = [],
        tokens: [String] = []
    ) {
        self.parkCount = parkCount
        self.visitCount = visitCount
        self.anchorLatitude = anchor.map { ($0.latitude * 1_000).rounded() / 1_000 }
        self.anchorLongitude = anchor.map { ($0.longitude * 1_000).rounded() / 1_000 }
        self.extra = extra
        self.tokens = tokens
    }

    private init(
        parkCount: Int,
        visitCount: Int,
        anchorLatitude: Double?,
        anchorLongitude: Double?,
        extra: [Double],
        tokens: [String]
    ) {
        self.parkCount = parkCount
        self.visitCount = visitCount
        self.anchorLatitude = anchorLatitude
        self.anchorLongitude = anchorLongitude
        self.extra = extra
        self.tokens = tokens
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
        self.tokens = []
    }
}


/// Holds the store's visit count between saves.
///
/// The count is one half of `StatsSignature`, which every screen builds inside its `body`
/// — and a `body` runs far more often than the store changes. On the map, where the camera
/// publishes a new region on every frame of a pan, that was two `COUNT` round trips to
/// SQLite per frame before a single pin was drawn. The number can only move when something
/// is written, so it is read once and then held until SwiftData says a save happened.
@MainActor
private final class VisitCountCache {
    static let shared = VisitCountCache()

    /// Keyed by context, so a test with its own container can never be answered with a
    /// count that belongs to a different store.
    private var cached: [ObjectIdentifier: Int] = [:]
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: .main
        ) { _ in
            // Any save at all clears everything: erring towards a re-read is cheap, and a
            // stale count would silently freeze a screen's figures.
            MainActor.assumeIsolated { VisitCountCache.shared.cached.removeAll() }
        }
    }

    func count(in context: ModelContext) -> Int {
        let key = ObjectIdentifier(context)
        if let existing = cached[key] { return existing }
        let fresh = (try? context.fetchCount(FetchDescriptor<Visit>())) ?? 0
        cached[key] = fresh
        return fresh
    }

    /// For a caller that has just written and wants the next read to go to the store,
    /// without waiting for the save notification to land.
    func invalidate() {
        cached.removeAll()
    }
}

extension ModelContext {
    /// Total logged visits, counted by the store instead of by walking relationships, and
    /// remembered between saves. See `VisitCountCache`.
    @MainActor
    func visitCount() -> Int {
        VisitCountCache.shared.count(in: self)
    }

    /// Drops the remembered visit count. Only needed by code that mutates without saving.
    @MainActor
    func invalidateVisitCount() {
        VisitCountCache.shared.invalidate()
    }
}
