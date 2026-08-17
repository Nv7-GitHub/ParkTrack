import SwiftUI
import SwiftData

/// Manages the places the app has swept exhaustively.
///
/// Indexing is what turns a completion percentage from "of the parks I happen to have found"
/// into "of the parks that are actually there", so this screen is deliberately explicit about
/// which places are indexed, when they were swept, and what a number means before they are.
struct RegionIndexManager: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ServiceHub.self) private var services
    @Environment(LocationProvider.self) private var location

    @Query(sort: \RegionIndex.name) private var indexes: [RegionIndex]

    @State private var query = ""
    @State private var kind: RegionKind = .city
    @State private var message: String?
    @State private var completer = PlaceCompleter()

    private var indexer: RegionIndexer? { services.regionIndexer }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(
                                "Index a place",
                                subtitle: "Sweeps every park in it once, then remembers the total forever"
                            )
                            Picker("What to index", selection: $kind) {
                                ForEach(RegionIndexer.indexableKinds) { option in
                                    Text(option.title).tag(option)
                                }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityLabel("Index a city or a county")

                            HStack(spacing: 8) {
                                Image(systemName: "magnifyingglass")
                                    .foregroundStyle(Theme.textSecondary)
                                TextField(kind == .city ? "Search for a city" : "Search for a county", text: $query)
                                    .textInputAutocapitalization(.words)
                                    .autocorrectionDisabled()
                                    .submitLabel(.search)
                                    .onSubmit { Task { await indexTyped() } }
                                    .onChange(of: query) { _, new in completer.update(query: new) }
                                if !query.isEmpty {
                                    Button {
                                        query = ""
                                        completer.clear()
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Clear search")
                                }
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 12)
                            .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.tightCornerRadius, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.tightCornerRadius, style: .continuous)
                                    .strokeBorder(Theme.separator, lineWidth: 1)
                            )

                            // Suggestions as you type. Submitting the raw text still works, but
                            // picking a suggestion is unambiguous: many places share a name and
                            // only the full "city, state, country" resolves to the right one.
                            if !completer.suggestions.isEmpty {
                                VStack(spacing: 0) {
                                    ForEach(completer.suggestions.prefix(6)) { suggestion in
                                        Button {
                                            Task { await index(suggestion) }
                                        } label: {
                                            HStack(spacing: 10) {
                                                Image(systemName: kind == .county ? "map" : "building.2")
                                                    .font(.footnote)
                                                    .foregroundStyle(Theme.accent)
                                                VStack(alignment: .leading, spacing: 1) {
                                                    Text(suggestion.title)
                                                        .font(.subheadline.weight(.medium))
                                                        .foregroundStyle(Theme.textPrimary)
                                                    if !suggestion.subtitle.isEmpty {
                                                        Text(suggestion.subtitle)
                                                            .font(.caption)
                                                            .foregroundStyle(Theme.textSecondary)
                                                    }
                                                }
                                                Spacer(minLength: 8)
                                                if false {
                                                    ProgressView()
                                                } else {
                                                    Image(systemName: "arrow.down.circle")
                                                        .foregroundStyle(Theme.textSecondary)
                                                }
                                            }
                                            .padding(.vertical, 9)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .disabled((indexer?.isIndexing ?? false))
                                        if suggestion != completer.suggestions.prefix(6).last {
                                            Divider().overlay(Theme.separator)
                                        }
                                    }
                                }
                            } else if completer.isSearching {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text("Searching…")
                                        .font(.caption)
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            } else if query.trimmingCharacters(in: .whitespaces).count >= 2, !(indexer?.isIndexing ?? false) {
                                Text("No places matched \"\(query)\".")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }

                            Button {
                                Task { await indexHere() }
                            } label: {
                                Label("Index where I am", systemImage: "location.fill")
                                    .font(.subheadline.weight(.medium))
                            }
                            .buttonStyle(.bordered)
                            .tint(Theme.sky)
                            .disabled((indexer?.isIndexing ?? false) || location.currentLocation == nil)

                            if let active = indexer?.activeRegionName {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 8) {
                                        ProgressView()
                                        Text("Sweeping \(active)…")
                                            .font(.caption)
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                    IndexProgressView(progress: indexer?.progress)
                                }
                            }

                            if let message {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(Theme.sunset)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    // Records from an older indexer: still named, no longer believed.
                    let stale = indexes.filter(\.needsReindexing)
                    if !stale.isEmpty {
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionHeader(
                                    "Needs re-indexing",
                                    subtitle: "\(stale.count) place\(stale.count == 1 ? "" : "s") counted by an older version"
                                )
                                Text("Those totals came from a coarser search, so they're treated as partial until swept again. Re-indexing a county can take a few minutes.")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button {
                                    Task { await refreshStale() }
                                } label: {
                                    if (indexer?.isIndexing ?? false) {
                                        HStack(spacing: 8) {
                                            ProgressView()
                                            Text(indexer?.activeRegionName.map { "Sweeping \($0)…" } ?? "Working…")
                                        }
                                    } else {
                                        Label("Re-index \(stale.count) place\(stale.count == 1 ? "" : "s")", systemImage: "arrow.clockwise")
                                            .font(.subheadline.weight(.semibold))
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.accent)
                                .disabled((indexer?.isIndexing ?? false))
                            }
                        }
                    }

                    if indexes.isEmpty {
                        EmptyStateView(
                            systemImage: "square.stack.3d.down.right",
                            title: "Nothing indexed yet",
                            message: "Until a place is indexed, its percentage counts only the parks you've stumbled across — so it moves when your search radius does."
                        )
                    } else {
                        SectionHeader("Indexed places", subtitle: "\(indexes.count) cached, never re-swept unless you ask")
                        VStack(spacing: 10) {
                            ForEach(indexes) { region in
                                RegionIndexRow(region: region) {
                                    Task { await reindex(region) }
                                } onDelete: {
                                    delete(region)
                                }
                            }
                        }
                    }
                }
                .padding(16)
                .tabBarBottomInset()
            }
            .background(Theme.background)
            .navigationTitle("Region index")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func index(_ suggestion: PlaceSuggestion) async {
        guard let indexer else { return }
        message = nil
        let chosen = kind
        query = ""
        completer.clear()
        indexer.enqueue {
            if await indexer.indexSuggestion(suggestion, kind: chosen) == nil {
                message = indexer.lastError ?? "Couldn't index \(suggestion.title)."
            }
        }
    }

    private func indexTyped() async {
        guard let indexer else { return }
        message = nil
        let name = query
        let chosen = kind
        query = ""
        completer.clear()
        indexer.enqueue {
            if await indexer.indexPlace(named: name, kind: chosen) == nil {
                message = indexer.lastError ?? "Couldn't index \"\(name)\"."
            }
        }
    }

    private func indexHere() async {
        guard let indexer, let coordinate = location.currentLocation?.coordinate else { return }
        message = nil
        indexer.enqueue { await indexer.indexArea(around: coordinate) }
    }

    private func reindex(_ region: RegionIndex) async {
        guard let indexer else { return }
        indexer.enqueue { await indexer.reindex(region) }
    }

    private func refreshStale() async {
        guard let indexer else { return }
        indexer.enqueue { await indexer.refreshOutdatedIndexes() }
    }

    private func delete(_ region: RegionIndex) {
        services.modelContext?.delete(region)
    }
}

private struct RegionIndexRow: View {
    let region: RegionIndex
    let onReindex: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Card(padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(region.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    HStack(spacing: 6) {
                        Pill(text: region.kind.title, systemImage: "mappin.and.ellipse")
                        if region.isIndexing {
                            Pill(text: "Sweeping", systemImage: "arrow.triangle.2.circlepath", tint: Theme.sky)
                        } else if region.needsReindexing {
                            Pill(text: "Needs re-index", systemImage: "exclamationmark.arrow.circlepath", tint: Theme.sunset)
                        } else if region.isIndexed {
                            Pill(text: "\(region.parkCount) parks", systemImage: "tree.fill", tint: Theme.fern)
                            if region.isApproximate {
                                Pill(text: "Approximate", systemImage: "tilde", tint: Theme.bark)
                            }
                        }
                    }
                    if let indexedAt = region.indexedAt {
                        Text("Indexed \(Format.relative(indexedAt)) · \(Format.miles(region.radiusMiles)) radius")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer(minLength: 8)
                Menu {
                    Button("Re-index", systemImage: "arrow.clockwise", action: onReindex)
                    Button("Remove", systemImage: "trash", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityLabel("Options for \(region.displayName)")
            }
        }
    }
}

/// What the sweep behind an index is actually doing.
///
/// Indexing a county is hundreds of searches over several minutes. A bare spinner for that
/// long is indistinguishable from a hang, and the two failures it used to report — "it got
/// interrupted" and "couldn't index" — gave no clue how far it had got.
struct IndexProgressView: View {
    let progress: ParkDiscoveryService.SweepProgress?

    var body: some View {
        if let progress, progress.tilesTotal > 0 {
            VStack(alignment: .leading, spacing: 5) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.separator)
                        Capsule()
                            .fill(Theme.progressGradient)
                            .frame(width: max(4, geo.size.width * progress.fraction))
                            .animation(.smooth(duration: 0.3), value: progress.fraction)
                    }
                }
                .frame(height: 6)

                Text("Searched \(progress.tilesSearched) of \(progress.tilesTotal) areas · \(Format.parkCount(progress.parksFound)) found")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .contentTransition(.numericText())
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue("\(Int(progress.fraction * 100)) percent, \(progress.parksFound) parks found")
        }
    }
}
