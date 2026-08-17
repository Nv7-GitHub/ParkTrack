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
///
/// Every signature carries the store's revision, taken automatically on construction, so a
/// change no count can see — an index finishing, a date being cleared, a park being placed
/// in a city — still invalidates whatever was derived from it. Callers do not opt in: a
/// signature that could be built without it would be one more chance to ship a screen that
/// goes stale until relaunch. See `StoreRevision`.
struct StatsSignature: Equatable, Hashable {
    let storeRevision: Int
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
            tokens: tokens,
            storeRevision: storeRevision
        )
    }

    /// Counts supplied directly, which is how views build it: `parks.count` is free from
    /// the existing `@Query`, and the visit count comes from a `COUNT` on the store rather
    /// than by faulting every park's relationship.
    @MainActor
    init(
        parkCount: Int,
        visitCount: Int,
        anchor: CLLocationCoordinate2D? = nil,
        extra: [Double] = [],
        tokens: [String] = []
    ) {
        self.storeRevision = StoreRevision.shared.value
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
        tokens: [String],
        storeRevision: Int
    ) {
        self.storeRevision = storeRevision
        self.parkCount = parkCount
        self.visitCount = visitCount
        self.anchorLatitude = anchorLatitude
        self.anchorLongitude = anchorLongitude
        self.extra = extra
        self.tokens = tokens
    }

    @MainActor
    init(
        parks: [Park],
        anchor: CLLocationCoordinate2D? = nil,
        extra: [Double] = []
    ) {
        self.storeRevision = StoreRevision.shared.value
        self.parkCount = parks.count
        self.visitCount = parks.reduce(0) { $0 + $1.visitCount }
        self.anchorLatitude = anchor.map { ($0.latitude * 1_000).rounded() / 1_000 }
        self.anchorLongitude = anchor.map { ($0.longitude * 1_000).rounded() / 1_000 }
        self.extra = extra
        self.tokens = []
    }
}


/// What the store has been through, and how many visits are in it.
///
/// Two jobs, one observer, because both answer "has anything changed" and both are driven
/// by the same notification.
///
/// **The count** is half of every `StatsSignature`, which every screen builds inside its
/// `body` — and a `body` runs far more often than the store changes. On the map, where the
/// camera publishes a region on every frame of a pan, that was two `COUNT` round trips to
/// SQLite per frame before a pin was drawn. It can only move when something is written, so
/// it is read once and held until SwiftData says a save happened.
///
/// **The revision** is why that is not enough on its own. Counting parks and visits is a
/// proxy for "is the data the same", and it is a leaky one: finishing a region index writes
/// a park total onto a `RegionIndex`, clearing a date sets a flag on a visit that still
/// exists, and reverse-geocoding names a park's city — none of which move either count, and
/// all of which change what the screens should say. Every cache in the app therefore kept
/// showing the old answer until the app was relaunched and the caches started empty.
///
/// A counter bumped on every save is the honest key. It changes when the store changes and
/// at no other time, so it costs nothing per frame while making a stale cache impossible.
/// Being `@Observable`, reading it inside a signature is also what tells SwiftUI to
/// re-evaluate a screen once a save lands.
@Observable
@MainActor
final class StoreRevision {
    static let shared = StoreRevision()

    /// Bumped once per save. Only ever compared for equality.
    private(set) var value = 0

    /// Keyed by context, so a test with its own container can never be answered with a
    /// count that belongs to a different store.
    @ObservationIgnored private var cachedVisitCounts: [ObjectIdentifier: Int] = [:]
    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        // No queue, so a save made on the main thread — which is every save this app
        // performs — bumps the revision before `save()` returns. Hopping through the main
        // queue instead would leave one runloop turn in which a screen could read a
        // signature that still described the store as it was before the write.
        observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: nil
        ) { _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { StoreRevision.shared.bump() }
            } else {
                Task { @MainActor in StoreRevision.shared.bump() }
            }
        }
    }

    func visitCount(in context: ModelContext) -> Int {
        let key = ObjectIdentifier(context)
        if let existing = cachedVisitCounts[key] { return existing }
        let fresh = (try? context.fetchCount(FetchDescriptor<Visit>())) ?? 0
        cachedVisitCounts[key] = fresh
        return fresh
    }

    /// Records that the store changed. Called for you on every save; exposed for the rare
    /// caller that mutates and wants the screens to catch up before it saves.
    func bump() {
        cachedVisitCounts.removeAll()
        value &+= 1
    }
}

extension ModelContext {
    /// Total logged visits, counted by the store instead of by walking relationships, and
    /// remembered between saves. See `StoreRevision`.
    @MainActor
    func visitCount() -> Int {
        StoreRevision.shared.visitCount(in: self)
    }

}
