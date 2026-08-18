import Foundation
import MapKit

/// Finds entries in the catalogue that do not look like parks.
///
/// Map search deliberately covers everything on the map, because a landmark is often an easier
/// thing to search for than the park beside it. For a while tapping any of those results filed
/// it as a park, so catalogues contain cafés and shops that were only ever meant to move the
/// camera. This identifies them; it never removes anything on its own, because a wrong guess
/// here deletes somewhere the user has actually been.
enum ParkAudit {
    /// Entries that came from the map but no longer pass the test discovery applies to one.
    static func suspicious(_ parks: [Park]) -> [Park] {
        parks.filter { isSuspicious($0) }
    }

    static func isSuspicious(_ park: Park) -> Bool {
        // A hand-placed pin has neither a category nor an address: the user typed a name and
        // dropped it somewhere. Judging those would flag exactly the entries that were most
        // deliberate, so they are left alone whatever they are called.
        guard cameFromTheMap(park) else { return false }
        let category = park.categoryRaw.flatMap { $0.isEmpty ? nil : MKPointOfInterestCategory(rawValue: $0) }
        return !ParkDiscoveryService.isParkLike(name: park.name, category: category)
    }

    /// Whether this entry arrived from a map result rather than from the user's own hand.
    ///
    /// A search result always carries its placemark's address; nothing else does. This used
    /// to key on the category alone, which meant an uncategorised search result — an
    /// apartment block called "Parkside Esterra Park", say — read as hand-placed and was
    /// never offered for review, even though it is precisely what the filter now rejects.
    private static func cameFromTheMap(_ park: Park) -> Bool {
        if let raw = park.categoryRaw, !raw.isEmpty { return true }
        if let address = park.postalAddress, !address.isEmpty { return true }
        return false
    }

    /// Why an entry was flagged, in a few words, so a list of them can be read rather than
    /// trusted. A name that reads like a park's but carries no map category is the common
    /// case — the flats named after the park across the road.
    static func reason(for park: Park) -> String {
        // The playground category covers both a corner of a park and an indoor activity
        // business, so "the map calls this a playground" explains nothing about why a
        // robotics academy is on the list.
        if let raw = park.categoryRaw,
           MKPointOfInterestCategory(rawValue: raw) == ParkDiscoveryService.playgroundCategory,
           ParkDiscoveryService.namesABusiness(park.name) {
            return "Listed as a playground, but reads as a business"
        }
        if let label = categoryLabel(for: park) { return "The map calls this a \(label.lowercased())" }
        if hasParkLikeName(park.name) { return "Named like a park, but the map doesn't list it as one" }
        return "The map doesn't list this as a park"
    }

    private static func hasParkLikeName(_ name: String) -> Bool {
        ParkDiscoveryService.hasParkLikeName(name)
    }

    /// What the category says it is, in words, e.g. "MKPOICategoryCafe" becomes "Cafe".
    static func categoryLabel(for park: Park) -> String? {
        guard let raw = park.categoryRaw, !raw.isEmpty else { return nil }
        let stripped = raw.replacingOccurrences(of: "MKPOICategory", with: "")
        guard !stripped.isEmpty else { return nil }
        return stripped.replacingOccurrences(
            of: "([a-z])([A-Z])",
            with: "$1 $2",
            options: .regularExpression
        )
    }
}
