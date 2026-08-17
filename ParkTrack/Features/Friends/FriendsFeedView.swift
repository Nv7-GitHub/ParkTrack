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

    private var days: [Day] {
        let calendar = Calendar.current
        let all = friends.flatMap { $0.visits ?? [] }
        let grouped = Dictionary(grouping: all) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in
            Day(date: day, visits: (grouped[day] ?? []).sorted { $0.date > $1.date })
        }
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
            } else if days.isEmpty {
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
                        Text(Self.dayLabel(day.date))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .textCase(.uppercase)
                            .padding(.leading, 4)
                            .accessibilityAddTraits(.isHeader)

                        ForEach(day.visits) { visit in
                            FriendVisitRow(visit: visit)
                        }
                    }
                }
            }
        }
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
