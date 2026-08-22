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

    /// Set when this launch restored the store from a rebuild, so Settings can say so.
    private(set) static var didRebuildStorage = false

    static func makeContainer() -> ModelContainer {
        // Before anything opens the store, because emptying it underneath a live container
        // is not a thing SwiftData supports. `beginIfArmed` deletes the store files and
        // hands back the archive to put the contents back from; it has already verified that
        // archive against the store it is about to remove.
        let rebuildArchive = StorageRebuild.beginIfArmed()
        defer {
            if let rebuildArchive { restore(from: rebuildArchive) }
        }

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
            rebuiltContainer = container
            return container
        }

        if let container = try? ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        ) {
            isCloudSyncActive = false
            rebuiltContainer = container
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
            rebuiltContainer = container
            return container
        } catch {
            fatalError("Unable to create any model container: \(error)")
        }
    }

    /// Puts a rebuilt store's contents back.
    ///
    /// Failure here is survivable and deliberately quiet: the archive is left on disk and
    /// the attempt counter has already been raised, so the next launch tries once more and
    /// then gives up rather than looping. Losing the data would take both the restore and
    /// the retry failing, with the file still sitting in Documents either way.
    private static func restore(from archive: URL) {
        guard let container = rebuiltContainer else { return }
        let context = ModelContext(container)
        guard (try? DataExport.importArchive(at: archive, into: context)) != nil else { return }
        StorageRebuild.finish(archive)
        didRebuildStorage = true
    }

    /// The container `makeContainer` just built, so `restore` can reach it from the `defer`.
    private static var rebuiltContainer: ModelContainer?

    /// In-memory container for previews and tests.
    static func makeInMemoryContainer() -> ModelContainer {
        try! ModelContainer(
            for: schema,
            // `.none` explicitly, because the default is `.automatic` — and once the app
            // carries an iCloud entitlement that default applies here too. Every test then
            // stood up a CloudKit mirroring delegate against a store at /dev/null, which
            // cannot work and says so at length: hundreds of `CKAccountStatusNoAccount`
            // failures and background-task cancellations, buried between the assertions.
            // Nothing in a test wants to sync.
            configurations: ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        )
    }
}
