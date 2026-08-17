import Foundation
import CoreLocation
import SwiftData
import Observation

/// Holds the app's long-lived services so every screen shares one instance.
///
/// `ParkDiscoveryService` and `SocialService` both cache work in memory — swept map
/// tiles, in-flight searches, sync state — so a per-screen instance would re-query the
/// map each time a tab appeared and let two screens disagree about what is loading.
/// They also need a `ModelContext`, which only exists once a view is in the hierarchy,
/// so the hub is created empty and filled in from `RootView`'s `.task`.
@Observable
@MainActor
final class ServiceHub {
    private(set) var discovery: ParkDiscoveryService?
    private(set) var social: SocialService?
    private(set) var regionIndexer: RegionIndexer?
    private(set) var modelContext: ModelContext?

    /// The startup sweep, owned here rather than by a view.
    ///
    /// It used to hang off HomeView's `.task(id:)`, whose identity flips as the hub fills in
    /// — and SwiftUI cancels a task when its id changes. The sweep was therefore cancelled
    /// before its first request, so a fresh install found no parks at all and the region
    /// indexer then recorded a completed index of zero. Work this long-running belongs to
    /// the service layer, where view lifecycle cannot cut it short.
    private var startupTask: Task<Void, Never>?
    private(set) var hasRunStartupDiscovery = false

    /// Idempotent: `RootView`'s task can run again after a scene change without
    /// discarding the caches the services have already built up.
    func start(modelContext: ModelContext) {
        if discovery == nil {
            discovery = ParkDiscoveryService(modelContext: modelContext)
        }
        if social == nil {
            social = SocialService.makeDefault(modelContext: modelContext)
        }
        if regionIndexer == nil, let discovery {
            regionIndexer = RegionIndexer(modelContext: modelContext, discovery: discovery)
        }
        self.modelContext = modelContext
    }

    /// Sweeps around the user once per launch and indexes the city and county they're in.
    /// Safe to call repeatedly: later calls join the running sweep rather than starting one.
    func beginStartupDiscovery(around coordinate: CLLocationCoordinate2D, radiusMiles: Double) {
        guard !hasRunStartupDiscovery, startupTask == nil, let discovery else { return }
        hasRunStartupDiscovery = true
        startupTask = Task { [weak self] in
            await discovery.sweep(around: coordinate, radiusMiles: radiusMiles)
            if let context = self?.modelContext {
                await RegionResolver.shared.resolveMissingRegions(context: context, limit: 30)
            }
            await self?.regionIndexer?.indexArea(around: coordinate)
            self?.startupTask = nil
        }
    }

    /// Waits for the startup sweep, so a pull-to-refresh doesn't fight it.
    func awaitStartupDiscovery() async {
        await startupTask?.value
    }
}
