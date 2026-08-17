import SwiftUI
import SwiftData

/// Completion by administrative area — city, county or state — for whatever areas the
/// reverse geocoder has actually named. Nothing here is baked in: the buckets are simply
/// the places the user's own parks turned out to be in.
struct StatsRegionSection: View {
    let parks: [Park]
    let signature: StatsSignature

    @Environment(ServiceHub.self) private var services
    @Query private var indexes: [RegionIndex]
    @State private var isPresentingIndexManager = false
    let cache: StatsCache

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

    init(parks: [Park], signature: StatsSignature, cache: StatsCache) {
        self.parks = parks
        self.signature = signature
        self.cache = cache
    }

    private var completions: [RegionCompletion] { cache.completions(for: scope) }

    /// Changes whenever an index finishes or its count moves, so cached completions are
    /// recomputed against the new denominator.
    private var indexedFingerprint: Int {
        indexes.reduce(0) { $0 &+ $1.parkCount &+ ($1.isIndexed ? 1 : 0) }
    }

    private var shown: [RegionCompletion] {
        let all = completions
        guard !isExpanded, all.count > collapsedLimit else { return all }
        return Array(all.prefix(collapsedLimit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "Completion by area",
                subtitle: "Places you've started, most complete first"
            ) {
                Button {
                    isPresentingIndexManager = true
                } label: {
                    Label("Index", systemImage: "square.stack.3d.down.right")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(Theme.accent)
            }

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
                                    VStack(alignment: .leading, spacing: 4) {
                                        ProgressBar(
                                            title: completion.name,
                                            visited: completion.visited,
                                            total: completion.total,
                                            tint: Theme.chartColors[index % Theme.chartColors.count]
                                        )
                                        if !completion.isIndexed {
                                            Text("Partial — index \(completion.name) for a real total")
                                                .font(.caption2)
                                                .foregroundStyle(Theme.textSecondary)
                                        } else if completion.isApproximate {
                                            Text("At least this many — searching hit its limit. Index again to go further.")
                                                .font(.caption2)
                                                .foregroundStyle(Theme.textSecondary)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(completion.name)
                                .accessibilityValue(
                                    "\(completion.visited) of \(completion.total) parks visited"
                                        + (completion.isIndexed ? "" : ", partial count")
                                )
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
        .sheet(isPresented: $isPresentingIndexManager) {
            RegionIndexManager()
        }
        .sheet(item: $detail) { completion in
            RegionProgressSheet(initialCompletion: completion, origin: nil)
                .presentationDetents([.medium, .large])
        }
    }
}
