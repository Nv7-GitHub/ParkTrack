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
    /// Parks whose name and category both fail the test discovery applies to a search result.
    ///
    /// Anything the user typed a name for themselves is left alone: a hand-added park has no
    /// category and can be called whatever its owner calls it, so judging it by name would
    /// flag exactly the entries that were most deliberate.
    static func suspicious(_ parks: [Park]) -> [Park] {
        parks.filter { isSuspicious($0) }
    }

    static func isSuspicious(_ park: Park) -> Bool {
        guard let raw = park.categoryRaw, !raw.isEmpty else {
            // No category at all is what a hand-placed pin looks like. Left alone.
            return false
        }
        let category = MKPointOfInterestCategory(rawValue: raw)
        return !ParkDiscoveryService.isParkLike(name: park.name, category: category)
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
