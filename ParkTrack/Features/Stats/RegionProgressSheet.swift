import SwiftUI
import SwiftData
import CoreLocation

/// What you've done and what's left in one place, rather than only what's left.
///
/// A list of remaining parks answers "where next" but not "how am I doing here", and the
/// second question is the one the completion bar raises. Both halves are shown, with the
/// visited side collapsed by default so the actionable half is what you land on.
struct RegionProgressSheet: View {
    /// The snapshot this sheet was opened with. Everything index-related is re-read live from
    /// the store below, because the sheet used to keep showing "index this place" after the
    /// sweep had finished — the value it was handed at presentation never changed, so the only
    /// way to see the result was to close and reopen.
    let initialCompletion: RegionCompletion
    var origin: CLLocation?

    @Query private var indexes: [RegionIndex]

    /// The snapshot with its index facts refreshed from whatever is in the store now.
    private var completion: RegionCompletion {
        guard let record = indexes.first(where: { $0.identifier == initialCompletion.identifier }),
              record.isIndexed else {
            return initialCompletion
        }
        var updated = initialCompletion
        updated.isIndexed = true
        updated.isApproximate = record.isApproximate
        updated.indexedAt = record.indexedAt
        updated.total = max(record.parkCount, initialCompletion.visited + initialCompletion.remaining.count)
        updated.fraction = updated.total == 0 ? 0 : Double(updated.visited) / Double(updated.total)
        return updated
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(ServiceHub.self) private var services

    @State private var showsVisited = false
    @State private var indexError: String?

    private var visitedParks: [Park] {
        completion.visitedParks.sorted { ($0.lastVisitDate ?? .distantPast) > ($1.lastVisitDate ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                    header

                    indexStatus

                    if !completion.isIndexed {
                        indexPrompt
                    } else if completion.isApproximate {
                        approximateNote
                        continueButton
                    }

                    section(
                        title: "Still to go",
                        count: completion.remaining.count,
                        parks: completion.remaining,
                        emptyMessage: "Nothing left here — you've been to every park \(completion.name) is known to have."
                    )

                    DisclosureGroup(isExpanded: $showsVisited) {
                        VStack(spacing: 8) {
                            ForEach(visitedParks, id: \.identifier) { park in
                                RegionParkRow(park: park, origin: origin, isVisited: true)
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("Been to · \(completion.visited)")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .disabled(completion.visited == 0)
                    .tint(Theme.accent)
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle(completion.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    ProgressRing(fraction: completion.fraction, lineWidth: 9)
                        .frame(width: 76, height: 76)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(completion.visited) of \(completion.total) visited")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        Text("\(Format.parkCount(completion.remaining.count)) still to go in \(completion.name).")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let indexedAt = completion.indexedAt {
                            Text("Indexed \(Format.relative(indexedAt))")
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
        }
    }

    /// Progress, queue position or failure for this region, wherever it is in its life.
    @ViewBuilder
    private var indexStatus: some View {
        let state = services.regionIndexer?.state(forIdentifier: completion.identifier, name: completion.name)
        if state != nil || indexError != nil {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    switch state {
                    case .sweeping(let progress):
                        Text("Searching \(completion.name)…")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        IndexProgressView(progress: progress)
                    case .queued(let position):
                        Text(queueLabel(position: position))
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    case .none:
                        EmptyView()
                    }

                    if let indexError {
                        Text(indexError)
                            .font(.caption)
                            .foregroundStyle(Theme.sunset)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var indexPrompt: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("This total is only what you've found")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Index \(completion.name) and the count becomes every park it actually has, so the percentage stops moving as you explore.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    Task { await index() }
                } label: {
                    if isIndexingThis {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Indexing \(completion.name)…")
                        }
                    } else {
                        Label("Index \(completion.name)", systemImage: "square.stack.3d.down.right")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(services.regionIndexer?.isIndexing ?? false)

                // This region's own standing. One shared bar meant opening another city showed
                // whatever sweep happened to be running somewhere else.

            }
        }
    }

    /// Picks up where the last sweep stopped, which is cheap now that finished tiles are
    /// remembered at the grade they were searched.
    private var continueButton: some View {
        Button {
            Task { await index() }
        } label: {
            if isIndexingThis {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Searching \(completion.name)…")
                }
            } else {
                Label("Keep searching \(completion.name)", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
            }
        }
        .buttonStyle(.bordered)
        .tint(Theme.accent)
        .disabled(services.regionIndexer?.isIndexing ?? false)
    }

    private var approximateNote: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text("At least this many")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Some searches in \(completion.name) came back full — the map returns only about twenty-five results each — so there are probably more parks than this. Carrying on covers any ground the last pass never reached, skipping everything it did, though it cannot get past the cap on a search that was already full.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func section(title: String, count: Int, parks: [Park], emptyMessage: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(title) · \(count)")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            if parks.isEmpty {
                Text(emptyMessage)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 8) {
                    ForEach(parks, id: \.identifier) { park in
                        RegionParkRow(park: park, origin: origin, isVisited: false)
                    }
                }
            }
        }
    }

    /// True only while this region is the one being swept.
    private var isIndexingThis: Bool {
        services.regionIndexer?.state(
            forIdentifier: completion.identifier,
            name: completion.name
        ) != nil
    }

    /// Names what the wait is actually for. Saying "starting shortly" while something else
    /// held the queue for minutes was the least useful thing it could have said.
    private func queueLabel(position: Int) -> String {
        if let blocking = services.regionIndexer?.blockingRegionName {
            return "Waiting for \(blocking) to finish…"
        }
        return position == 0 ? "Starting shortly…" : "Waiting behind \(position) other place\(position == 1 ? "" : "s")."
    }

    private func index() async {
        guard let indexer = services.regionIndexer else { return }
        indexError = nil
        let name = completion.name
        let kind = completion.kind
        // Handed to the service, so closing this sheet does not stop the sweep.
        indexer.enqueue(identifier: completion.identifier, name: name) {
            if await indexer.indexPlace(named: name, kind: kind) == nil {
                indexError = indexer.lastError ?? "Couldn't index \(name)."
            }
        }
    }
}

private struct RegionParkRow: View {
    let park: Park
    var origin: CLLocation?
    let isVisited: Bool

    var body: some View {
        NavigationLink {
            ParkDetailView(park: park)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isVisited ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isVisited ? Theme.accent : Theme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(park.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if isVisited, let last = park.lastVisitDate {
                        Text("Last visit \(Format.date(last)) · \(Format.parkCount(park.visitCount).replacingOccurrences(of: "park", with: "visit"))")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    } else if let origin {
                        Text(Format.distance(park.distance(from: origin)))
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.tightCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
