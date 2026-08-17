import Foundation
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

    /// Idempotent: `RootView`'s task can run again after a scene change without
    /// discarding the caches the services have already built up.
    func start(modelContext: ModelContext) {
        if discovery == nil {
            discovery = ParkDiscoveryService(modelContext: modelContext)
        }
        if social == nil {
            social = SocialService.makeDefault(modelContext: modelContext)
        }
    }
}
