import SwiftUI

/// What the leaderboard ranks on. Four metrics rather than one because "most parks"
/// permanently favours whoever started first; streak and this-month give someone new
/// a column they can actually win.
enum LeaderboardMetric: String, CaseIterable, Identifiable {
    case parks
    case month
    case cities
    case streak

    var id: String { rawValue }

    var title: String {
        switch self {
        case .parks: "Parks"
        case .month: "Month"
        case .cities: "Cities"
        case .streak: "Streak"
        }
    }

    var caption: String {
        switch self {
        case .parks: "Total parks visited"
        case .month: "New parks this month"
        case .cities: "Cities with a visit"
        case .streak: "Current weekly streak"
        }
    }

    var systemImage: String {
        switch self {
        case .parks: "tree.fill"
        case .month: "calendar"
        case .cities: "building.2.fill"
        case .streak: "flame.fill"
        }
    }
}

/// A leaderboard row's data, flattened so ranking never has to care whether it is
/// looking at the user or at a mirrored friend.
struct LeaderboardEntry: Identifiable, Equatable {
    let id: String
    let name: String
    let isMe: Bool
    let friend: Friend?
    let totalParks: Int
    let parksThisMonth: Int
    let citiesCount: Int
    let streakWeeks: Int

    func value(for metric: LeaderboardMetric) -> Int {
        switch metric {
        case .parks: totalParks
        case .month: parksThisMonth
        case .cities: citiesCount
        case .streak: streakWeeks
        }
    }

    func valueLabel(for metric: LeaderboardMetric) -> String {
        switch metric {
        case .streak: streakWeeks == 1 ? "1 wk" : "\(streakWeeks) wks"
        default: "\(value(for: metric))"
        }
    }

    /// Compared field by field: `Friend` is a reference type whose identity says
    /// nothing about whether the row needs to redraw.
    static func == (lhs: LeaderboardEntry, rhs: LeaderboardEntry) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.isMe == rhs.isMe
            && lhs.totalParks == rhs.totalParks
            && lhs.parksThisMonth == rhs.parksThisMonth
            && lhs.citiesCount == rhs.citiesCount
            && lhs.streakWeeks == rhs.streakWeeks
    }
}

extension LeaderboardEntry {
    init(friend: Friend) {
        self.init(
            id: friend.friendCode,
            name: friend.displayName.isEmpty ? friend.friendCode : friend.displayName,
            isMe: false,
            friend: friend,
            totalParks: friend.totalParks,
            parksThisMonth: friend.parksThisMonth,
            citiesCount: friend.citiesCount,
            streakWeeks: friend.currentStreakWeeks
        )
    }
}

/// You and your friends, ranked. The user is always drawn in the list — highlighted
/// in place when they're near the top, and pinned below the fold with their real rank
/// when they aren't, so the screen never hides where you actually stand.
struct FriendsLeaderboardView: View {
    let entries: [LeaderboardEntry]
    @Binding var metric: LeaderboardMetric
    var onAddFriend: () -> Void

    private static let visibleCount = 5

    private struct Row: Identifiable {
        let rank: Int
        let entry: LeaderboardEntry
        var id: String { entry.id }
    }

    private var ranked: [LeaderboardEntry] {
        entries.sorted { lhs, rhs in
            let left = lhs.value(for: metric)
            let right = rhs.value(for: metric)
            if left == right {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return left > right
        }
    }

    private var topRows: [Row] {
        ranked.prefix(Self.visibleCount).enumerated().map { Row(rank: $0.offset + 1, entry: $0.element) }
    }

    /// Set only when the user fell outside the visible top.
    private var myOverflowRow: Row? {
        guard let index = ranked.firstIndex(where: { $0.isMe }), index >= Self.visibleCount else { return nil }
        return Row(rank: index + 1, entry: ranked[index])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("Leaderboard", subtitle: metric.caption)

            Picker("Rank by", selection: $metric) {
                ForEach(LeaderboardMetric.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Rank by")

            if entries.count <= 1 {
                Card {
                    EmptyStateView(
                        systemImage: "person.2",
                        title: "No friends yet",
                        message: "Add someone by their 6-character code to compare parks, cities and streaks.",
                        actionTitle: "Add a friend",
                        action: onAddFriend
                    )
                }
            } else {
                Card(padding: 8) {
                    VStack(spacing: 2) {
                        ForEach(topRows) { row in
                            rowView(row)
                        }
                        if let myOverflowRow {
                            HStack(spacing: 8) {
                                Rectangle()
                                    .fill(Theme.separator)
                                    .frame(height: 1)
                                Text("Your position")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Theme.textSecondary)
                                Rectangle()
                                    .fill(Theme.separator)
                                    .frame(height: 1)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .accessibilityHidden(true)
                            rowView(myOverflowRow)
                        }
                    }
                    .animation(.smooth(duration: 0.45), value: topRows.map(\.id))
                    .animation(.smooth(duration: 0.35), value: metric)
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        if let friend = row.entry.friend {
            NavigationLink(value: friend) {
                FriendsLeaderboardRow(rank: row.rank, entry: row.entry, metric: metric, isNavigable: true)
            }
            .buttonStyle(.plain)
        } else {
            FriendsLeaderboardRow(rank: row.rank, entry: row.entry, metric: metric, isNavigable: false)
        }
    }
}

/// A single ranked person. Medal colours for the podium, plain numerals below it.
struct FriendsLeaderboardRow: View {
    let rank: Int
    let entry: LeaderboardEntry
    let metric: LeaderboardMetric
    var isNavigable: Bool = false

    private var medalColor: Color? {
        switch rank {
        case 1: Color(hex: 0xE0A526)
        case 2: Color(hex: 0x9AA5AD)
        case 3: Color(hex: 0xB87333)
        default: nil
        }
    }

    private var secondaryLine: String {
        switch metric {
        case .parks: "\(entry.citiesCount) cities · \(entry.parksThisMonth) this month"
        case .month: "\(Format.parkCount(entry.totalParks)) all time"
        case .cities: "\(Format.parkCount(entry.totalParks)) all time"
        case .streak: "\(entry.parksThisMonth) new this month"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            rankBadge
            FriendAvatar(name: entry.name, isMe: entry.isMe)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.isMe ? "\(entry.name) (you)" : entry.name)
                    .font(.subheadline.weight(entry.isMe ? .bold : .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(secondaryLine)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(entry.valueLabel(for: metric))
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(entry.isMe ? Theme.accent : Theme.textPrimary)

            if isNavigable {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            entry.isMe ? Theme.accent.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: Theme.tightCornerRadius, style: .continuous)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rank). \(entry.isMe ? "You, " : "")\(entry.name)")
        .accessibilityValue("\(entry.valueLabel(for: metric)) — \(metric.caption)")
        .accessibilityAddTraits(isNavigable ? .isButton : [])
    }

    private var rankBadge: some View {
        ZStack {
            Circle()
                .fill((medalColor ?? Theme.textSecondary).opacity(medalColor == nil ? 0.12 : 0.22))
            if let medalColor {
                Image(systemName: "medal.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(medalColor)
            } else {
                Text("\(rank)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }
}
