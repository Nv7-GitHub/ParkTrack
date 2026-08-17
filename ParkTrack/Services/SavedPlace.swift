import Foundation
import CoreLocation
import SwiftUI

/// A place the user measures from.
///
/// Home was the only one for a long time, but "how much have I explored" is a different
/// question around school or work than it is around where you sleep — and the answer is
/// interesting precisely because those are the places you are without choosing to be.
/// Nothing here is required: a place that isn't set simply doesn't appear.
enum SavedPlaceKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case home, school, work

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .school: return "School"
        case .work: return "Work"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .school: return "graduationcap.fill"
        case .work: return "briefcase.fill"
        }
    }

    /// How it reads inside a sentence, as opposed to on a segmented control.
    var sheetLabel: String {
        switch self {
        case .home: return "home"
        case .school: return "school"
        case .work: return "work"
        }
    }

    var tint: Color {
        switch self {
        case .home: return Theme.fern
        case .school: return Theme.sky
        case .work: return Theme.bark
        }
    }

    var unsetMessage: String {
        switch self {
        case .home: return "Not set. Stats fall back to wherever you are right now."
        case .school: return "Not set. Add it to measure how much you've explored around school."
        case .work: return "Not set. Add it to measure how much you've explored around work."
        }
    }
}
