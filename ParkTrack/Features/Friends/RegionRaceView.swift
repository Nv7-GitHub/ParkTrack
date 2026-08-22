import SwiftUI
import SwiftData
import CoreLocation

/// Head-to-head completion of one indexed place.
///
/// Everyone here is counted against the same total, which is the whole reason indexing
/// exists: without a swept denominator each person would be measured against however much
/// ground they personally happened to cover, and the ranking would mean nothing.
struct RegionRaceView: View {
    let parks: [Park]
    let friends: [Friend]
    let myName: String

    @Environment(AppSettings.self) private var settings
    @Environment(LocationProvider.self) private var location

    @Query(sort: \RegionIndex.name) private var indexes: [RegionIndex]
    @Query private var myExclusions: [ExcludedPlace]

    /// Remembered across launches. Which race you are following is a standing interest, not
    /// something to re-pick every time the app opens.
    @AppStorage("friends.raceRegion") private var selection: String = ""
    @State private var isManagingVisibility = false

    /// Indexed places, nearest first.
    ///
    /// Distance from wherever you are, rather than alphabetically. The race you want is
    /// almost always the one you are standing in, and a name-ordered list puts it wherever
    /// its initial happens to fall. Falling back to home when there is no fix, and to the
    /// existing name order when there is neither, so the list is never arbitrary.
    private var races: [RegionIndex] {
        let visible = indexes.filter { $0.isIndexed && !$0.isHiddenFromRaces }
        guard let origin = raceOrigin else { return visible }

        return visible
            .map { (region: $0, metres: origin.distance(from: $0.centre)) }
            .sorted { $0.metres < $1.metres }
            .map(\.region)
    }

    private var raceOrigin: CLLocation? {
        if let current = location.currentLocation { return current }
        return settings.homeCoordinate.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
    }

    private var active: RegionIndex? {
        races.first { $0.identifier == selection } ?? races.first
    }

    private struct Standing: Identifiable {
        let id: String
        let name: String
        let visited: Int
        let total: Int
        let isMe: Bool
        var fraction: Double { total > 0 ? Double(visited) / Double(total) : 0 }
    }

    /// Everyone in this race counts against one denominator: the raw indexed total, less
    /// every place anyone racing has struck off.
    ///
    /// Without the subtraction the two sides are not comparable. A rejection removes a park
    /// from the rejecter's catalogue but not from anyone else's total, so the person who has
    /// tidied their data is silently measured against a different number than the person who
    /// has not. See `RegionFairness`.
    private func standings(for region: RegionIndex) -> [Standing] {
        let mine = parks.filter { RegionIndex.identity(kind: region.kind, park: $0) == region.identifier }
        let mineExcluded = myExclusions.map(ExclusionPoint.init)
        let racers = friends.filter { ($0.regions ?? []).contains { $0.regionIdentifier == region.identifier } }

        let union = racers.reduce(mineExcluded) { combined, friend in
            RegionFairness.union(combined, (friend.exclusions ?? []).map(ExclusionPoint.init))
        }

        let raw = max(
            RegionFairness.rawTotal(for: region, localCount: mine.count, myExclusions: mineExcluded),
            racers.compactMap { friend in
                (friend.regions ?? []).first { $0.regionIdentifier == region.identifier }?.total
            }.max() ?? 0
        )
        let total = RegionFairness.fairTotal(rawTotal: raw, region: region, union: union)

        var rows = [Standing(
            id: "me",
            name: myName.isEmpty ? "You" : myName,
            visited: mine.count(where: \.isVisited),
            total: total,
            isMe: true
        )]

        for friend in racers {
            guard let progress = (friend.regions ?? []).first(where: { $0.regionIdentifier == region.identifier }) else { continue }
            rows.append(Standing(
                id: friend.friendCode,
                name: friend.displayName,
                visited: progress.visited,
                total: total,
                isMe: false
            ))
        }

        return rows.sorted {
            $0.visited == $1.visited ? $0.name < $1.name : $0.visited > $1.visited
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "Race a place",
                subtitle: "Everyone counted against the same indexed total"
            ) {
                if indexes.contains(where: \.isIndexed) {
                    Button {
                        isManagingVisibility = true
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.fern)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Choose which places to race")
                }
            }

            if races.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No indexed places yet")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Index a city or county from the Stats tab and it becomes a race you can run against your friends.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if let active {
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        if races.count > 1 {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(races) { region in
                                        Button {
                                            withAnimation(.smooth(duration: 0.25)) {
                                                selection = region.identifier
                                            }
                                        } label: {
                                            Pill(
                                                text: region.name,
                                                systemImage: region.kind == .county ? "map" : "building.2",
                                                tint: region.identifier == active.identifier ? Theme.fern : Theme.bark
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }

                        Text("\(active.displayName) · \(active.parkCount) parks")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)

                        let rows = standings(for: active)
                        VStack(spacing: 12) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { position, row in
                                HStack(spacing: 10) {
                                    Text("\(position + 1)")
                                        .font(.caption.weight(.bold).monospacedDigit())
                                        .foregroundStyle(Theme.textSecondary)
                                        .frame(width: 18)
                                    ProgressBar(
                                        title: row.name,
                                        visited: row.visited,
                                        total: row.total,
                                        tint: row.isMe ? Theme.fern : Theme.chartColors[(position + 1) % Theme.chartColors.count]
                                    )
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, row.isMe ? 8 : 0)
                                .background(
                                    row.isMe
                                        ? RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fern.opacity(0.10))
                                        : nil
                                )
                            }
                        }
                        .animation(.smooth(duration: 0.4), value: rows.map(\.id))

                        if rows.count == 1 {
                            Text("Only you so far. A friend appears here once they've indexed \(active.name) too.")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $isManagingVisibility) {
            RaceVisibilitySheet(origin: raceOrigin)
        }
    }
}

private extension RegionIndex {
    var centre: CLLocation {
        CLLocation(latitude: centerLatitude, longitude: centerLongitude)
    }
}
