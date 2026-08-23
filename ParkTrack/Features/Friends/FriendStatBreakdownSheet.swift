import SwiftUI

/// The list behind a figure on a friend's profile — the same idea as `StatBreakdownSheet`,
/// over the only material there is for someone else: what they have shared.
///
/// It reuses `BreakdownRow` rather than reimplementing it, so a friend's cities read
/// exactly like your own. What it cannot reuse is the source: your breakdowns are built
/// from `Park` objects with localities, first-visit dates and distances, and a friend
/// arrives as a flat list of visits carrying a name, a place label and a day.
///
/// Where a figure and its list can disagree, the sheet says so rather than quietly showing
/// the shorter answer. Their headline numbers are computed over their whole library and
/// travel in one small record; the visits behind those numbers travel separately and may
/// still be arriving. A number and a list that disagree with no explanation is worse than
/// either alone.
struct FriendStatBreakdownSheet: View {
    let kind: Kind
    let friend: Friend

    @Environment(\.dismiss) private var dismiss

    enum Kind: String, Identifiable, CaseIterable {
        case parksVisited
        case allVisits
        case cities
        case currentStreak
        case newThisMonth

        var id: String { rawValue }

        var title: String {
            switch self {
            case .parksVisited: "Parks visited"
            case .allVisits: "Total visits"
            case .cities: "Cities"
            case .currentStreak: "Current streak"
            case .newThisMonth: "New this month"
            }
        }

        func emptyMessage(name: String) -> String {
            switch self {
            case .parksVisited:
                "\(name) hasn't shared any parks yet."
            case .allVisits:
                "Nothing logged yet. Parks \(name) marked visited without a date aren't trips."
            case .cities:
                "Cities appear once the parks \(name) shares have been placed on the map."
            case .currentStreak:
                "A streak starts the week they log a visit, and holds as long as they log one every week."
            case .newThisMonth:
                "No park \(name) shared has its first visit in this month."
            }
        }

        /// The figure on the tile, which comes from their profile rather than from anything
        /// here — computed across their whole library, including visits they have not shared.
        func headline(_ friend: Friend) -> Int {
            switch self {
            case .parksVisited: friend.totalParks
            case .allVisits: friend.totalVisits
            case .cities: friend.citiesCount
            case .currentStreak: friend.currentStreakWeeks
            case .newThisMonth: friend.parksThisMonth
            }
        }
    }

    private var visits: [FriendVisit] { (friend.visits ?? []).orderedByRecency() }
    private var datedVisits: [FriendVisit] { visits.filter { !$0.isUndated } }

    var body: some View {
        let rows = rows()

        NavigationStack {
            Group {
                if rows.isEmpty {
                    EmptyStateView(
                        systemImage: "tray",
                        title: "Nothing here yet",
                        message: kind.emptyMessage(name: friend.displayName)
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    List {
                        if let note = shortfallNote(rows: rows) {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .listRowBackground(Theme.surface)
                        }
                        ForEach(rows) { row in
                            BreakdownRow(row: row)
                                .listRowBackground(Theme.surface)
                        }
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
                        Text(friend.displayName)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
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

    /// Said out loud when the list is shorter than the figure that opened it.
    ///
    /// Normally there is nothing to say: everything a person logs is published, so the two
    /// agree. They part company while a first share is still uploading — their profile is one
    /// small record and lands immediately, their visits follow behind — and for a figure the
    /// shared data cannot fully reconstruct.
    func shortfallNote(rows: [BreakdownRow.Model]) -> String? {
        let headline = kind.headline(friend)
        guard headline > rows.count else { return nil }
        return "\(friend.displayName) counts \(headline). These are the \(rows.count) behind visits they've shared so far — the rest may still be syncing."
    }

    // MARK: - Rows

    /// Internal so the tests can hold each list against the figure that opened it.
    func rows() -> [BreakdownRow.Model] {
        switch kind {
        case .parksVisited: parkRows(visits)
        case .newThisMonth: parkRows(parksFirstVisitedThisMonth())
        case .allVisits: visitRows()
        case .cities: cityRows()
        case .currentStreak: weekRows()
        }
    }

    /// One row per park, keyed by name and place so two parks called "Riverside Park" in
    /// different cities stay two parks. A friend's visits carry no park identifier — they
    /// were indexed on the other phone, against a catalogue this one has never seen.
    private func parkRows(_ visits: [FriendVisit]) -> [BreakdownRow.Model] {
        var byPark: [String: [FriendVisit]] = [:]
        for visit in visits {
            byPark[Self.parkKey(visit), default: []].append(visit)
        }

        return byPark
            .map { key, visits -> (key: String, visits: [FriendVisit], first: Date?) in
                (key, visits, visits.filter { !$0.isUndated }.map(\.date).min())
            }
            .sorted { lhs, rhs in
                switch (lhs.first, rhs.first) {
                case let (l?, r?): l > r
                // A park they only marked has no date to sort by, so it goes after the ones
                // that do rather than pretending to be the oldest or the newest.
                case (nil, _?): false
                case (_?, nil): true
                default: lhs.visits[0].parkName.localizedStandardCompare(rhs.visits[0].parkName) == .orderedAscending
                }
            }
            .map { entry in
                BreakdownRow.Model(
                    id: entry.key,
                    title: entry.visits[0].parkName,
                    subtitle: entry.visits[0].regionLabel,
                    trailing: entry.first.map(Format.date) ?? "No date",
                    detail: entry.visits.count > 1 ? "\(entry.visits.count) visits" : nil,
                    systemImage: "tree.fill",
                    tint: Theme.fern
                )
            }
    }

    /// Parks whose first shared visit fell in this month — the rule their headline counts by.
    private func parksFirstVisitedThisMonth() -> [FriendVisit] {
        let calendar = Calendar.current
        let now = Date()
        var firstByPark: [String: Date] = [:]
        for visit in datedVisits {
            let key = Self.parkKey(visit)
            firstByPark[key] = min(firstByPark[key] ?? visit.date, visit.date)
        }
        return datedVisits.filter { visit in
            guard let first = firstByPark[Self.parkKey(visit)] else { return false }
            return first == visit.date && calendar.isDate(first, equalTo: now, toGranularity: .month)
        }
    }

    /// Dated visits only, matching the figure that opens this list.
    private func visitRows() -> [BreakdownRow.Model] {
        datedVisits.map { visit in
            BreakdownRow.Model(
                id: visit.identifier,
                title: visit.parkName,
                subtitle: visit.regionLabel,
                trailing: Format.date(visit.date),
                detail: visit.rating > 0 ? String(repeating: "★", count: visit.rating) : nil,
                systemImage: "figure.walk",
                tint: Theme.sky
            )
        }
    }

    /// Grouped by the place label a visit carries, counting parks rather than visits — the
    /// same thing your own cities list counts.
    private func cityRows() -> [BreakdownRow.Model] {
        var parksPerPlace: [String: Set<String>] = [:]
        for visit in visits {
            guard let place = visit.regionLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !place.isEmpty else { continue }
            parksPerPlace[place, default: []].insert(Self.parkKey(visit))
        }
        return parksPerPlace
            .sorted { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }
            .map { place, parks in
                BreakdownRow.Model(
                    id: place,
                    title: place,
                    subtitle: nil,
                    trailing: Format.parkCount(parks.count),
                    detail: nil,
                    systemImage: "building.2.fill",
                    tint: Theme.sky
                )
            }
    }

    /// The same rule as your own streak, run over their shared visits — one implementation,
    /// so the two cannot drift apart and disagree about the same person.
    private func weekRows() -> [BreakdownRow.Model] {
        let weeks = StatsEngine.streakWeeks(
            visits: datedVisits.map { (date: $0.date, parkKey: Self.parkKey($0)) },
            now: Date(),
            calendar: .current
        ).current

        return weeks.reversed().map { week in
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

    /// Name plus rounded position. Coordinates alone would split a park whose two visits
    /// were logged from opposite ends of it; the name alone would merge every "Memorial
    /// Park" in the country into one row.
    static func parkKey(_ visit: FriendVisit) -> String {
        String(format: "%@|%.3f,%.3f", visit.parkName, visit.latitude, visit.longitude)
    }
}
