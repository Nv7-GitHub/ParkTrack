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
        /// `[kind.rawValue: [latitude, longitude]]`, so a new kind of place needs no new key.
        static let places = "settings.places"
        /// `[kind.rawValue: label]`.
        static let placeLabels = "settings.placeLabels"
        static let didMigratePlaces = "settings.places.migrated"
        static let displayName = "settings.displayName"
        static let friendCode = "settings.friendCode"
        static let customRadiusMiles = "settings.customRadiusMiles"
        static let hasCompletedOnboarding = "settings.hasCompletedOnboarding"
    }

    /// The radius rings the completion screens are built around.
    static let defaultRadiiMiles: [Double] = [2.5, 5, 10]

    private let defaults: UserDefaults

    /// Every place the user has saved, as `[kind.rawValue: [latitude, longitude]]`.
    ///
    /// One dictionary rather than a property per kind: the screens ask "which places exist"
    /// far more often than they ask about any particular one, and a place that has been
    /// removed has to disappear from every picker without anything special being written for
    /// it. Stored flat so a new kind needs no migration.
    private(set) var placeCoordinates: [String: [Double]] {
        didSet { defaults.set(placeCoordinates, forKey: Key.places) }
    }

    private(set) var placeLabels: [String: String] {
        didSet { defaults.set(placeLabels, forKey: Key.placeLabels) }
    }

    func coordinate(for kind: SavedPlaceKind) -> CLLocationCoordinate2D? {
        guard let pair = placeCoordinates[kind.rawValue], pair.count == 2 else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }

    /// Passing nil removes the place, which is how a picker loses a segment.
    func setCoordinate(_ coordinate: CLLocationCoordinate2D?, for kind: SavedPlaceKind) {
        if let coordinate, CLLocationCoordinate2DIsValid(coordinate) {
            placeCoordinates[kind.rawValue] = [coordinate.latitude, coordinate.longitude]
        } else {
            placeCoordinates.removeValue(forKey: kind.rawValue)
            placeLabels.removeValue(forKey: kind.rawValue)
        }
    }

    func label(for kind: SavedPlaceKind) -> String {
        let stored = placeLabels[kind.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (stored?.isEmpty == false ? stored : nil) ?? kind.title
    }

    func setLabel(_ label: String, for kind: SavedPlaceKind) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            placeLabels.removeValue(forKey: kind.rawValue)
        } else {
            placeLabels[kind.rawValue] = trimmed
        }
    }

    /// The places that actually exist, in a fixed order so a picker never reshuffles itself.
    var savedPlaces: [SavedPlaceKind] {
        SavedPlaceKind.allCases.filter { coordinate(for: $0) != nil }
    }

    /// Home, still reachable by name because it is the fallback centre the whole app uses
    /// when there is no location fix.
    var homeCoordinate: CLLocationCoordinate2D? {
        get { coordinate(for: .home) }
        set { setCoordinate(newValue, for: .home) }
    }

    var homeLabel: String {
        get { label(for: .home) }
        set { setLabel(newValue, for: .home) }
    }
    var displayName: String { didSet { defaults.set(displayName, forKey: Key.displayName) } }
    var friendCode: String { didSet { defaults.set(friendCode, forKey: Key.friendCode) } }
    var customRadiusMiles: Double { didSet { defaults.set(customRadiusMiles, forKey: Key.customRadiusMiles) } }
    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Assembled in locals: the stored properties observe their own writes, and they
        // cannot be read at all until every one of them has a value.
        var places = defaults.dictionary(forKey: Key.places) as? [String: [Double]] ?? [:]
        var labels = defaults.dictionary(forKey: Key.placeLabels) as? [String: String] ?? [:]

        // A home saved before places existed lives under its own two keys. Carried over once,
        // rather than left behind — losing it would silently recentre every ring in the app.
        //
        // Exactly once, and the old keys are cleared afterwards. Repeating it on every
        // launch would make removing home impossible: the absence it leaves behind looks
        // identical to a home that has not been migrated yet, so the next launch would put
        // it straight back.
        if !defaults.bool(forKey: Key.didMigratePlaces) {
            if places[SavedPlaceKind.home.rawValue] == nil,
               defaults.object(forKey: Key.homeLatitude) != nil,
               defaults.object(forKey: Key.homeLongitude) != nil {
                places[SavedPlaceKind.home.rawValue] = [
                    defaults.double(forKey: Key.homeLatitude),
                    defaults.double(forKey: Key.homeLongitude)
                ]
                if let legacyLabel = defaults.string(forKey: Key.homeLabel), !legacyLabel.isEmpty {
                    labels[SavedPlaceKind.home.rawValue] = legacyLabel
                }
            }
            defaults.removeObject(forKey: Key.homeLatitude)
            defaults.removeObject(forKey: Key.homeLongitude)
            defaults.removeObject(forKey: Key.homeLabel)
            defaults.set(true, forKey: Key.didMigratePlaces)
        }
        placeCoordinates = places
        placeLabels = labels

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

// MARK: - Backup

extension AppSettings {
    /// The preferences a backup carries. Everything here lives in `UserDefaults` rather
    /// than the store, so a restore that only merged SwiftData would silently drop it —
    /// which is what used to happen to school and work.
    var backupSettings: BackupSettings {
        BackupSettings(
            displayName: displayName,
            friendCode: friendCode,
            placeCoordinates: placeCoordinates,
            placeLabels: placeLabels,
            customRadiusMiles: customRadiusMiles,
            hasCompletedOnboarding: hasCompletedOnboarding
        )
    }

    /// Restores preferences from a backup, filling blanks rather than overwriting.
    ///
    /// The same rule the park merge follows, and for the same reason: importing a backup
    /// into an install that has already been used must not throw away what the user has
    /// since typed. A place already set locally stays where it is; one that is missing is
    /// taken from the file.
    ///
    /// `friendCode` is the exception worth naming. A fresh install invents a random code in
    /// its initialiser, so by the time an import runs there is always a local one — and
    /// keeping it would leave every friend who saved the old code unable to find the user.
    /// The backup's code therefore wins whenever the user has not yet been given a name,
    /// which is the reliable marker of an install that has not really been used.
    @discardableResult
    func apply(_ settings: BackupSettings) -> Bool {
        var changed = false
        let isFreshInstall = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if isFreshInstall, !settings.displayName.isEmpty {
            displayName = settings.displayName
            changed = true
        }
        if isFreshInstall, !settings.friendCode.isEmpty, settings.friendCode != friendCode {
            friendCode = settings.friendCode
            changed = true
        }

        for kind in SavedPlaceKind.allCases where coordinate(for: kind) == nil {
            guard let pair = settings.placeCoordinates[kind.rawValue], pair.count == 2 else { continue }
            let coordinate = CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
            guard CLLocationCoordinate2DIsValid(coordinate) else { continue }
            setCoordinate(coordinate, for: kind)
            if let label = settings.placeLabels[kind.rawValue], !label.isEmpty {
                setLabel(label, for: kind)
            }
            changed = true
        }

        if isFreshInstall, settings.customRadiusMiles > 0 {
            customRadiusMiles = settings.customRadiusMiles
            changed = true
        }
        if settings.hasCompletedOnboarding, !hasCompletedOnboarding {
            hasCompletedOnboarding = true
            changed = true
        }
        return changed
    }
}
