import SwiftUI

/// Where a friend's profile pushes when they have shared more than the profile shows.
///
/// The same route Home takes for the user's own log: a section shows a handful, and the
/// obvious thing to do with a handful is ask for the rest. Keeping the rest on its own
/// screen is what stops the profile becoming a hundred cards with the places they've
/// struck off, and the button to remove them, stranded at the bottom.
struct FriendVisitsRoute: Hashable {
    let friend: Friend
}

struct FriendVisitListScreen: View {
    let friend: Friend

    /// Trips first, newest first, then whatever they merely marked — the same order the
    /// profile shows, so the five at the top of one are the five at the top of the other.
    private var visits: [FriendVisit] {
        (friend.visits ?? []).orderedByRecency()
    }

    private var subtitle: String {
        let marked = visits.count(where: \.isUndated)
        guard marked > 0 else { return "\(visits.count) shared visit\(visits.count == 1 ? "" : "s")" }
        return "\(visits.count) shared, \(marked) marked visited"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Their visits", subtitle: subtitle)

                if visits.isEmpty {
                    Card {
                        EmptyStateView(
                            systemImage: "leaf",
                            title: "Nothing shared yet",
                            message: "\(friend.displayName) hasn't shared any visits. Pull to refresh on the Friends tab to check again."
                        )
                    }
                } else {
                    ForEach(visits) { visit in
                        FriendVisitRow(visit: visit, showsFriendName: false)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .background(Theme.background)
        .navigationTitle(friend.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}
