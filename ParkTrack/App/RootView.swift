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
    @State private var selection: Tab = .home

    enum Tab: Hashable {
        case home, map, parks, stats, friends
    }

    var body: some View {
        TabView(selection: $selection) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(Tab.home)

            MapScreen()
                .tabItem { Label("Map", systemImage: "map.fill") }
                .tag(Tab.map)

            ParksListScreen()
                .tabItem { Label("Parks", systemImage: "tree.fill") }
                .tag(Tab.parks)

            StatsScreen()
                .tabItem { Label("Stats", systemImage: "chart.bar.fill") }
                .tag(Tab.stats)

            FriendsScreen()
                .tabItem { Label("Friends", systemImage: "person.2.fill") }
                .tag(Tab.friends)
        }
        .environment(services)
        .task {
            services.start(modelContext: modelContext)
            location.requestAuthorization()
            location.start()
        }
    }
}
