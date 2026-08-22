import Foundation
import SwiftData

/// Builds the app's SwiftData stack.
///
/// CloudKit mirroring is only usable when the app is signed with an iCloud container
/// entitlement. Rather than crashing where that isn't true (simulator, unsigned builds,
/// no iCloud account), we try the synced configuration first and fall back to a purely
/// local store. The app is fully functional either way.
enum PersistenceController {
    static let schema = Schema([
        Park.self,
        Visit.self,
        MediaItem.self,
        Friend.self,
        FriendVisit.self,
        RegionIndex.self,
        ScannedArea.self,
        ExcludedPlace.self,
        FriendRegionProgress.self,
        FriendExclusion.self
    ])

    /// True when the running build actually got a CloudKit-backed store.
    private(set) static var isCloudSyncActive = false

    static func makeContainer() -> ModelContainer {
        // Asking for CloudKit only when the build can actually use it.
        //
        // `ModelConfiguration(cloudKitDatabase: .automatic)` succeeds whether or not the app
        // is entitled: the mirroring delegate is set up eagerly and only discovers there is
        // no container or no account later, asynchronously, on a background queue. So this
        // used to report sync as active on every unsigned build and every simulator — the
        // About screen said "Parks, visits and media sync to your other devices" while
        // CoreData logged `CKAccountStatusNoAccount` and nothing left the phone.
        //
        // Checking the entitlement first makes the flag mean what it says, and spares
        // unentitled builds the cost and the log noise of a mirror that cannot work.
        if CloudKitAvailability.hasICloudEntitlement,
           let container = try? ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
           ) {
            isCloudSyncActive = true
            return container
        }

        if let container = try? ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        ) {
            isCloudSyncActive = false
            return container
        }

        // Last resort: an in-memory store keeps the app usable for the session instead of
        // refusing to launch, e.g. if the on-disk store is corrupt or unmigratable.
        do {
            let container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            )
            isCloudSyncActive = false
            return container
        } catch {
            fatalError("Unable to create any model container: \(error)")
        }
    }

    /// In-memory container for previews and tests.
    static func makeInMemoryContainer() -> ModelContainer {
        try! ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
    }
}
