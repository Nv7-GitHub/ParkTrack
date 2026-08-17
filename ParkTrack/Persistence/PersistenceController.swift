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
        FriendRegionProgress.self
    ])

    /// True when the running build actually got a CloudKit-backed store.
    private(set) static var isCloudSyncActive = false

    static func makeContainer() -> ModelContainer {
        if let container = try? ModelContainer(
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
