import SwiftUI

/// Reverse-chronological list of everything your friends have logged, grouped by day.
///
/// Reads straight from the local mirror rather than from the backend, so the feed is
/// there the instant the tab opens and stays readable with no connection; pulling to
/// refresh is what goes to the network.
struct FriendsFeedView: View {
    let friends: [Friend]
    var onAddFriend: () -> Void

    private struct Day: Identifiable {
        let date: Date
        let visits: [FriendVisit]
        var id: Date { date }
    }

    private var allVisits: [FriendVisit] {
        friends.flatMap { $0.visits ?? [] }
    }

    /// Only the trips. A park someone merely marked carries the moment they tapped it, so
    /// grouping it by that date filed a backlog cleared this afternoon under "Today" — at
    /// the very top of the feed, above everything that actually happened. Those go in one
    /// group of their own, after every real day.
    private var days: [Day] {
        let calendar = Calendar.current
        let dated = allVisits.filter { !$0.isUndated }
        let grouped = Dictionary(grouping: dated) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in
            Day(date: day, visits: (grouped[day] ?? []).sorted { $0.date > $1.date })
        }
    }

    private var markedVisits: [FriendVisit] {
        allVisits.filter(\.isUndated).sorted { $0.date > $1.date }
    }

    private var subtitle: String {
        let count = friends.reduce(0) { $0 + ($1.visits?.count ?? 0) }
        guard count > 0 else { return "What your friends have been visiting" }
        return "\(count) shared visit\(count == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            SectionHeader("Feed", subtitle: subtitle)

            if friends.isEmpty {
                Card {
                    EmptyStateView(
                        systemImage: "person.2",
                        title: "No friends yet",
                        message: "Add someone by their 6-character code and their visits will show up here.",
                        actionTitle: "Add a friend",
                        action: onAddFriend
                    )
                }
            } else if days.isEmpty, markedVisits.isEmpty {
                Card {
                    EmptyStateView(
                        systemImage: "leaf",
                        title: "Nothing shared yet",
                        message: "When your friends log a park, it'll appear here. Pull down to check again."
                    )
                }
            } else {
                ForEach(days) { day in
                    VStack(alignment: .leading, spacing: 10) {
                        dayHeader(Self.dayLabel(day.date))

                        ForEach(day.visits) { visit in
                            FriendVisitRow(visit: visit)
                        }
                    }
                }

                if !markedVisits.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        dayHeader("No date")

                        ForEach(markedVisits) { visit in
                            FriendVisitRow(visit: visit)
                        }
                    }
                }
            }
        }
    }

    private func dayHeader(_ label: String) -> some View {
        Text(label)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
            .textCase(.uppercase)
            .padding(.leading, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private static func dayLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return Format.date(date)
    }
}
