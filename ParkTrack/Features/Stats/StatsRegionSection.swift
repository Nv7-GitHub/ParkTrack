import SwiftUI

/// Completion by administrative area — city, county or state — for whatever areas the
/// reverse geocoder has actually named. Nothing here is baked in: the buckets are simply
/// the places the user's own parks turned out to be in.
struct StatsRegionSection: View {
    let parks: [Park]

    enum Scope: String, CaseIterable, Identifiable {
        case city, county, state

        var id: String { rawValue }

        var title: String {
            switch self {
            case .city: return "City"
            case .county: return "County"
            case .state: return "State"
            }
        }

        var noun: String { title.lowercased() }
    }

    @State private var scope: Scope = .city
    @State private var isExpanded = false
    @State private var detail: RegionCompletion?

    private let collapsedLimit = 6

    init(parks: [Park]) {
        self.parks = parks
    }

    private var completions: [RegionCompletion] {
        switch scope {
        case .city: return StatsEngine.completionByCity(parks: parks)
        case .county: return StatsEngine.completionByCounty(parks: parks)
        case .state: return StatsEngine.completionByState(parks: parks)
        }
    }

    private var shown: [RegionCompletion] {
        let all = completions
        guard !isExpanded, all.count > collapsedLimit else { return all }
        return Array(all.prefix(collapsedLimit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                "Completion by area",
                subtitle: "Sorted by how many parks each area holds"
            )

            Card {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Area type", selection: $scope) {
                        ForEach(Scope.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Group areas by")

                    let all = completions
                    if all.isEmpty {
                        StatsChartPlaceholder(
                            systemImage: "globe.americas",
                            message: "No \(scope.noun) names resolved yet. They fill in as parks are looked up."
                        )
                    } else {
                        VStack(spacing: 14) {
                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, completion in
                                Button {
                                    detail = completion
                                } label: {
                                    ProgressBar(
                                        title: completion.name,
                                        visited: completion.visited,
                                        total: completion.total,
                                        tint: Theme.chartColors[index % Theme.chartColors.count]
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(completion.name)
                                .accessibilityValue("\(completion.visited) of \(completion.total) parks visited")
                                .accessibilityHint("Shows the parks you still have left")
                                .accessibilityAddTraits(.isButton)
                            }
                        }
                        .animation(.smooth(duration: 0.4), value: shown.map(\.id))

                        if all.count > collapsedLimit {
                            Button {
                                withAnimation(.smooth(duration: 0.35)) { isExpanded.toggle() }
                            } label: {
                                Label(
                                    isExpanded ? "Show fewer" : "Show all \(all.count)",
                                    systemImage: isExpanded ? "chevron.up" : "chevron.down"
                                )
                                .font(.caption.weight(.medium))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
        }
        .sheet(item: $detail) { completion in
            StatsRemainingParksSheet(
                title: completion.name,
                subtitle: "in \(completion.name)",
                parks: completion.remaining
            )
            .presentationDetents([.medium, .large])
        }
    }
}
