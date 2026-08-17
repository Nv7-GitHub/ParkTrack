import Foundation
import CoreLocation
import SwiftUI
import Observation

/// Lightweight user preferences that don't warrant a SwiftData model.
@Observable
@MainActor
final class AppSettings {
    private enum Key {
        static let homeLatitude = "settings.home.latitude"
        static let homeLongitude = "settings.home.longitude"
        static let homeLabel = "settings.home.label"
        static let displayName = "settings.displayName"
        static let friendCode = "settings.friendCode"
        static let customRadiusMiles = "settings.customRadiusMiles"
        static let hasCompletedOnboarding = "settings.hasCompletedOnboarding"
    }

    /// The radius rings the completion screens are built around.
    static let defaultRadiiMiles: [Double] = [2.5, 5, 10]

    private let defaults: UserDefaults

    var homeCoordinate: CLLocationCoordinate2D? {
        didSet {
            defaults.set(homeCoordinate?.latitude, forKey: Key.homeLatitude)
            defaults.set(homeCoordinate?.longitude, forKey: Key.homeLongitude)
        }
    }
    var homeLabel: String { didSet { defaults.set(homeLabel, forKey: Key.homeLabel) } }
    var displayName: String { didSet { defaults.set(displayName, forKey: Key.displayName) } }
    var friendCode: String { didSet { defaults.set(friendCode, forKey: Key.friendCode) } }
    var customRadiusMiles: Double { didSet { defaults.set(customRadiusMiles, forKey: Key.customRadiusMiles) } }
    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Key.homeLatitude) != nil,
           defaults.object(forKey: Key.homeLongitude) != nil {
            homeCoordinate = CLLocationCoordinate2D(
                latitude: defaults.double(forKey: Key.homeLatitude),
                longitude: defaults.double(forKey: Key.homeLongitude)
            )
        } else {
            homeCoordinate = nil
        }
        homeLabel = defaults.string(forKey: Key.homeLabel) ?? "Home"
        displayName = defaults.string(forKey: Key.displayName) ?? ""
        friendCode = defaults.string(forKey: Key.friendCode) ?? AppSettings.generateFriendCode()
        let storedRadius = defaults.double(forKey: Key.customRadiusMiles)
        customRadiusMiles = storedRadius > 0 ? storedRadius : 25
        hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
        defaults.set(friendCode, forKey: Key.friendCode)
    }

    var radiiMiles: [Double] {
        (AppSettings.defaultRadiiMiles + [customRadiusMiles]).sorted()
    }

    /// Six characters from an alphabet without look-alikes, so codes are easy to read aloud.
    static func generateFriendCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }
}
