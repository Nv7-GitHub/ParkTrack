import SwiftUI
import SwiftData
import CoreLocation

/// What you've done and what's left in one place, rather than only what's left.
///
/// A list of remaining parks answers "where next" but not "how am I doing here", and the
/// second question is the one the completion bar raises. Both halves are shown, with the
/// visited side collapsed by default so the actionable half is what you land on.
struct RegionProgressSheet: View {
    let completion: RegionCompletion
    var origin: CLLocation?

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

                    if !completion.isIndexed {
                        indexPrompt
                    } else if completion.isApproximate {
                        approximateNote
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
                    if (services.regionIndexer?.isIndexing ?? false) {
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
                .disabled((services.regionIndexer?.isIndexing ?? false))

                if (services.regionIndexer?.isIndexing ?? false) {
                    IndexProgressView(progress: services.regionIndexer?.progress)
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

    private var approximateNote: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text("Approximate total")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(completion.name) is too large to search exhaustively, so this is a floor — there are probably more parks in it than the count shows.")
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

    private func index() async {
        guard let indexer = services.regionIndexer else { return }
        indexError = nil
        let name = completion.name
        let kind = completion.kind
        // Handed to the service, so closing this sheet does not stop the sweep.
        indexer.enqueue {
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
