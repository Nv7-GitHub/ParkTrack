import SwiftUI
import SwiftData

@main
struct ParkTrackApp: App {
    @State private var locationProvider = LocationProvider()
    @State private var settings = AppSettings()
    @State private var cloudSync = CloudSyncMonitor()
    private let container = PersistenceController.makeContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(locationProvider)
                .environment(settings)
                .environment(cloudSync)
                .tint(Theme.accent)
        }
        .modelContainer(container)
    }
}
