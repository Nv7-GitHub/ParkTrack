import Foundation
import Observation

/// Navigation that crosses tabs.
///
/// Almost everything in the app navigates within its own stack, but "show me this park on the
/// map" has to switch tabs and tell the map where to go — neither of which the park's own
/// screen can reach. Routing it through one observable object keeps that the only shared
/// navigation state rather than wiring bindings down through every view in between.
@Observable
@MainActor
final class AppRouter {
    var selectedTab: RootTab = .home

    /// A park the map should centre on and select. Cleared by the map once it has done so, so
    /// the same park can be sent again later.
    private(set) var mapFocus: Park?

    func showOnMap(_ park: Park) {
        mapFocus = park
        selectedTab = .map
    }

    func clearMapFocus() {
        mapFocus = nil
    }
}

/// The app's five destinations. Top level so the router can name one without depending on the
/// view that presents them.
enum RootTab: Hashable {
    case home, map, parks, stats, friends
}
