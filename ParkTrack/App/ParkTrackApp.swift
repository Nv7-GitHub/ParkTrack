import SwiftUI
import SwiftData

@main
struct ParkTrackApp: App {
    @State private var locationProvider = LocationProvider()
    @State private var settings = AppSettings()
    private let container = PersistenceController.makeContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(locationProvider)
                .environment(settings)
                .tint(Theme.accent)
        }
        .modelContainer(container)
    }
}
