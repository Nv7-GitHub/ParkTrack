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
    @State private var isWorking = false
    @State private var message: String?

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
                                TextField(kind == .city ? "City name" : "County name", text: $query)
                                    .textInputAutocapitalization(.words)
                                    .autocorrectionDisabled()
                                    .submitLabel(.search)
                                    .onSubmit { Task { await indexTyped() } }
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 12)
                                    .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.tightCornerRadius, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Theme.tightCornerRadius, style: .continuous)
                                            .strokeBorder(Theme.separator, lineWidth: 1)
                                    )

                                Button {
                                    Task { await indexTyped() }
                                } label: {
                                    if isWorking {
                                        ProgressView()
                                    } else {
                                        Image(systemName: "arrow.down.circle.fill")
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.accent)
                                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                            }

                            Button {
                                Task { await indexHere() }
                            } label: {
                                Label("Index where I am", systemImage: "location.fill")
                                    .font(.subheadline.weight(.medium))
                            }
                            .buttonStyle(.bordered)
                            .tint(Theme.sky)
                            .disabled(isWorking || location.currentLocation == nil)

                            if let active = indexer?.activeRegionName {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text("Sweeping \(active)…")
                                        .font(.caption)
                                        .foregroundStyle(Theme.textSecondary)
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

    private func indexTyped() async {
        guard let indexer, !isWorking else { return }
        isWorking = true
        message = nil
        let name = query
        if await indexer.indexPlace(named: name, kind: kind) != nil {
            query = ""
        } else {
            message = indexer.lastError ?? "Couldn't index \"\(name)\"."
        }
        isWorking = false
    }

    private func indexHere() async {
        guard let indexer, let coordinate = location.currentLocation?.coordinate, !isWorking else { return }
        isWorking = true
        message = nil
        await indexer.indexArea(around: coordinate)
        isWorking = false
    }

    private func reindex(_ region: RegionIndex) async {
        guard let indexer, !isWorking else { return }
        isWorking = true
        await indexer.reindex(region)
        isWorking = false
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
                        } else if region.isIndexed {
                            Pill(text: "\(region.parkCount) parks", systemImage: "tree.fill", tint: Theme.fern)
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
