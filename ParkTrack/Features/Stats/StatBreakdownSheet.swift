import SwiftUI
import CoreLocation

/// The list behind a headline figure.
///
/// A number on its own invites the question it cannot answer: seventeen cities, but which
/// ones? Every tile in the Stats headline opens the set it counted, so the figure can be
/// checked, explored, or simply enjoyed rather than just read.
struct StatBreakdownSheet: View {
    let kind: Kind
    let parks: [Park]
    var origin: CLLocation?

    @Environment(\.dismiss) private var dismiss

    /// Which figure was tapped. Each knows its own title and how to build its rows.
    enum Kind: String, Identifiable, CaseIterable {
        case visitedParks
        case allVisits
        case newThisMonth
        case newThisYear
        case cities
        case states
        case currentStreak
        case longestStreak

        var id: String { rawValue }

        var title: String {
            switch self {
            case .visitedParks: return "Parks visited"
            case .allVisits: return "Total visits"
            case .newThisMonth: return "New this month"
            case .newThisYear: return "New this year"
            case .cities: return "Cities"
            case .states: return "States and regions"
            case .currentStreak: return "Week streak"
            case .longestStreak: return "Longest streak"
            }
        }

        var emptyMessage: String {
            switch self {
            case .visitedParks: return "Log a visit and the park lands here."
            case .allVisits: return "Nothing logged yet."
            case .newThisMonth: return "No park's first visit has fallen in this month yet."
            case .newThisYear: return "No park's first visit has fallen in this year yet."
            case .cities: return "Cities appear once the map has named where your parks are."
            case .states: return "States appear once the map has named where your parks are."
            case .currentStreak:
                return "A streak starts the week you log a visit, and holds as long as you log one every week."
            case .longestStreak: return "Log visits in consecutive weeks and the run shows up here."
            }
        }
    }

    var body: some View {
        let rows = rows()

        NavigationStack {
            Group {
                if rows.isEmpty {
                    EmptyStateView(
                        systemImage: "tray",
                        title: "Nothing here yet",
                        message: kind.emptyMessage
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    List(rows) { row in
                        BreakdownRow(row: row)
                            .listRowBackground(Theme.surface)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(kind.title)
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        if !rows.isEmpty {
                            Text(subtitle(for: rows))
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func subtitle(for rows: [BreakdownRow.Model]) -> String {
        switch kind {
        case .cities:
            return rows.count == 1 ? "1 city" : "\(rows.count) cities"
        case .states:
            return rows.count == 1 ? "1 state or region" : "\(rows.count) states and regions"
        case .allVisits:
            return rows.count == 1 ? "1 visit" : "\(rows.count) visits"
        case .currentStreak, .longestStreak:
            return rows.count == 1 ? "1 week" : "\(rows.count) weeks"
        default:
            return Format.parkCount(rows.count)
        }
    }

    // MARK: - Rows

    /// Internal rather than private so the tests can hold each list against the figure that
    /// opened it. A breakdown that disagreed with its own headline would be worse than no
    /// breakdown at all.
    func rows() -> [BreakdownRow.Model] {
        switch kind {
        case .visitedParks:
            return parkRows(StatsEngine.visitedParks(parks))
        case .newThisMonth:
            return parkRows(parksFirstVisited(in: .month))
        case .newThisYear:
            return parkRows(parksFirstVisited(in: .year))
        case .allVisits:
            return visitRows()
        case .cities:
            return placeRows { $0.locality }
        case .states:
            return placeRows { $0.administrativeArea }
        case .currentStreak:
            return weekRows(StatsEngine.streakWeeks(parks: parks).current)
        case .longestStreak:
            return weekRows(StatsEngine.streakWeeks(parks: parks).longest)
        }
    }

    /// Parks whose *first* visit fell inside the current month or year — the same rule the
    /// headline counts by, so the list and the number can never disagree.
    private func parksFirstVisited(in granularity: Calendar.Component) -> [Park] {
        let calendar = Calendar.current
        let now = Date()
        return parks.filter { park in
            guard let first = park.firstVisitDate else { return false }
            return calendar.isDate(first, equalTo: now, toGranularity: granularity)
        }
    }

    private func parkRows(_ parks: [Park]) -> [BreakdownRow.Model] {
        parks
            .sorted { lhs, rhs in
                switch (lhs.firstVisitDate, rhs.firstVisitDate) {
                case let (l?, r?): return l > r
                // A park marked visited has no date to sort by, so it goes after the ones
                // that do rather than pretending to be the oldest or the newest.
                case (nil, _?): return false
                case (_?, nil): return true
                default: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            }
            .map { park in
                BreakdownRow.Model(
                    id: park.identifier,
                    title: park.name,
                    subtitle: park.regionLabel,
                    trailing: park.firstVisitDate.map(Format.date) ?? "No date",
                    detail: origin.map { Format.distance(park.distance(from: $0)) },
                    systemImage: "tree.fill",
                    tint: Theme.fern
                )
            }
    }

    private func visitRows() -> [BreakdownRow.Model] {
        let byIdentifier = Dictionary(
            parks.map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return parks.flatMap { $0.visits ?? [] }
            .orderedByRecency()
            .map { visit in
                let park = visit.park.flatMap { byIdentifier[$0.identifier] }
                return BreakdownRow.Model(
                    id: visit.identifier.uuidString,
                    title: park?.name ?? "Unknown park",
                    subtitle: park?.regionLabel,
                    trailing: visit.isUndated ? "No date" : Format.date(visit.date),
                    detail: visit.rating > 0 ? String(repeating: "★", count: visit.rating) : nil,
                    systemImage: "figure.walk",
                    tint: Theme.sky
                )
            }
    }

    /// Places the user has actually been, with how many parks in each — the same set the
    /// headline's distinct count is taken from, which is visited parks only.
    private func placeRows(_ key: (Park) -> String?) -> [BreakdownRow.Model] {
        var counts: [String: Int] = [:]
        for park in StatsEngine.visitedParks(parks) {
            guard let name = key(park)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { continue }
            counts[name, default: 0] += 1
        }
        return counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { name, count in
                BreakdownRow.Model(
                    id: name,
                    title: name,
                    subtitle: nil,
                    trailing: Format.parkCount(count),
                    detail: nil,
                    systemImage: kind == .cities ? "building.2.fill" : "map.fill",
                    tint: kind == .cities ? Theme.sky : Theme.canopy
                )
            }
    }

    private func weekRows(_ weeks: [StreakWeek]) -> [BreakdownRow.Model] {
        weeks.reversed().map { week in
            BreakdownRow.Model(
                id: ISO8601DateFormatter().string(from: week.start),
                title: "Week of \(Format.date(week.start))",
                subtitle: week.parks == 1 ? "1 park" : "\(week.parks) parks",
                trailing: week.visits == 1 ? "1 visit" : "\(week.visits) visits",
                detail: nil,
                systemImage: "flame.fill",
                tint: Theme.sunset
            )
        }
    }
}

/// One line of a breakdown. Deliberately one shape for every kind, so a park, a visit, a
/// city and a week all read the same way down the list.
struct BreakdownRow: View {
    struct Model: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let trailing: String?
        let detail: String?
        let systemImage: String
        let tint: Color
    }

    let row: Model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(row.tint)
                .frame(width: 30, height: 30)
                .background(row.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                if let trailing = row.trailing {
                    Text(trailing)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                if let detail = row.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary.opacity(0.8))
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
