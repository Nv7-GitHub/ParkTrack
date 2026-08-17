import SwiftUI
import SwiftData

/// The five destinations of the app. Each tab owns its own navigation stack so
/// switching tabs preserves where you were.
///
/// This is also where the shared services are born: they need the model context that
/// only exists inside the view hierarchy, so the hub is created here and injected into
/// the environment rather than each screen building its own copy.
struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(LocationProvider.self) private var location
    @State private var services = ServiceHub()
    @State private var router = AppRouter()

    var body: some View {
        TabView(selection: $router.selectedTab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(RootTab.home)

            MapScreen()
                .tabItem { Label("Map", systemImage: "map.fill") }
                .tag(RootTab.map)

            ParksListScreen()
                .tabItem { Label("Parks", systemImage: "tree.fill") }
                .tag(RootTab.parks)

            StatsScreen()
                .tabItem { Label("Stats", systemImage: "chart.bar.fill") }
                .tag(RootTab.stats)

            FriendsScreen()
                .tabItem { Label("Friends", systemImage: "person.2.fill") }
                .tag(RootTab.friends)
        }
        .environment(services)
        .environment(router)
        .task {
            services.start(modelContext: modelContext)
            location.requestAuthorization()
            location.start()
        }
    }
}
