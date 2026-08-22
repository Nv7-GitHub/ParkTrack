import SwiftUI
import SwiftData
import MapKit

/// Borrowing a friend's judgement about what isn't a park.
///
/// Deciding the map is wrong about a place is work, and it is the same work for everyone
/// who walks the same ground — so a friend who has already done it is worth borrowing from.
/// Nothing here happens on its own: connecting to someone changes nobody's catalogue, and
/// this screen only ever acts when the button at the bottom is pressed.
///
/// The care is all in what can be ticked. Striking a park off deletes it, and deleting a
/// park cascades to its visits and their photos, so a row that would cost something starts
/// unticked and says what it would cost. A row whose target is ambiguous cannot be ticked at
/// all until the person has opened it and said which park they meant.
struct AdoptExclusionsSheet: View {
    let friend: Friend

    @Environment(\.modelContext) private var modelContext
    @Environment(ServiceHub.self) private var services
    @Environment(\.dismiss) private var dismiss

    @Query private var parks: [Park]
    @Query private var alreadyExcluded: [ExcludedPlace]

    @State private var selected: Set<String> = []
    @State private var resolved: [String: Park] = [:]
    @State private var previewing: Park?
    @State private var disambiguating: AdoptableExclusion?
    @State private var isConfirming = false
    @State private var hasPreparedSelection = false

    // MARK: - Data

    private var rows: [AdoptableExclusion] {
        AdoptableExclusion.list(
            from: (friend.exclusions ?? []).sorted { $0.name < $1.name },
            parks: parks,
            alreadyExcluded: alreadyExcluded
        )
    }

    /// A row the person has disambiguated behaves exactly like an unambiguous one from then
    /// on, including inheriting the cost of whatever park they chose.
    private func effective(_ row: AdoptableExclusion) -> AdoptableExclusion {
        guard let chosen = resolved[row.identifier] else { return row }
        return AdoptableExclusion(
            identifier: row.identifier,
            name: row.name,
            latitude: row.latitude,
            longitude: row.longitude,
            match: .exact,
            park: chosen,
            visitCount: chosen.visitCount,
            mediaCount: (chosen.visits ?? []).reduce(0) { $0 + ($1.media?.count ?? 0) }
        )
    }

    private var effectiveRows: [AdoptableExclusion] { rows.map(effective) }

    private var selectedRows: [AdoptableExclusion] {
        effectiveRows.filter { selected.contains($0.identifier) }
    }

    private var destructiveRows: [AdoptableExclusion] {
        selectedRows.filter(\.wouldDeleteVisits)
    }

    private var selectableRows: [AdoptableExclusion] {
        effectiveRows.filter(\.canBeSelected)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if rows.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .background(Theme.background)
            .navigationTitle("Not a park")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if !selectableRows.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button(selected.isEmpty ? "Select all" : "Deselect all") {
                            selected = selected.isEmpty
                                ? Set(selectableRows.map(\.identifier))
                                : []
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { applyBar }
        }
        .sheet(item: $previewing) { park in
            ParkQuickLookSheet(park: park, onLogVisit: {})
        }
        .sheet(item: $disambiguating) { row in
            disambiguationSheet(for: row)
        }
        .onAppear {
            guard !hasPreparedSelection else { return }
            hasPreparedSelection = true
            selected = Set(effectiveRows.filter(\.isSelectedByDefault).map(\.identifier))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal")
                .font(.largeTitle)
                .foregroundStyle(Theme.fern)
            Text("Nothing to borrow")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("\(friend.displayName) hasn't struck anything off that you haven't already, or that you don't have.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(friend.displayName) says these aren't parks. Nothing changes until you apply.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)

                ForEach(effectiveRows) { row in
                    Card {
                        AdoptExclusionRow(
                            row: row,
                            isSelected: selected.contains(row.identifier),
                            onToggle: { toggle(row) },
                            onOpen: { open(row) }
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var applyBar: some View {
        VStack(spacing: 8) {
            if !destructiveRows.isEmpty {
                Label(
                    "\(destructiveRows.count) of these would delete visits you've logged.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.sunset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                if destructiveRows.isEmpty {
                    apply()
                } else {
                    isConfirming = true
                }
            } label: {
                Text(selected.isEmpty ? "Nothing selected" : "Strike off \(selected.count)")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(selected.isEmpty ? Theme.textSecondary.opacity(0.2) : Theme.fern, in: Capsule())
                    .foregroundStyle(selected.isEmpty ? Theme.textSecondary : .white)
            }
            .buttonStyle(.plain)
            .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .confirmationDialog(
            "Delete visits too?",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Strike off \(selected.count)", role: .destructive) { apply() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(destructiveMessage)
        }
    }

    private var destructiveMessage: String {
        let visits = destructiveRows.reduce(0) { $0 + $1.visitCount }
        let media = destructiveRows.reduce(0) { $0 + $1.mediaCount }
        var sentence = "\(destructiveRows.count) of the places you've selected "
        sentence += destructiveRows.count == 1 ? "has " : "have "
        sentence += "visits you logged. Striking them off deletes \(visits) \(visits == 1 ? "visit" : "visits")"
        if media > 0 {
            sentence += " and \(media) \(media == 1 ? "photo or video" : "photos and videos")"
        }
        sentence += ". This can't be undone."
        return sentence
    }

    // MARK: - Disambiguation

    /// Two parks of the same name close together — Boston Common and the other Boston
    /// Common — are the case the matcher deliberately refuses to guess at. The person picks.
    private func disambiguationSheet(for row: AdoptableExclusion) -> some View {
        let candidates = ExclusionMatcher.candidates(
            name: row.name,
            coordinate: row.coordinate,
            among: parks
        )

        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("You have \(candidates.count) parks called \"\(row.name)\" close together. Which one does \(friend.displayName) mean?")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(candidates, id: \.park.identifier) { candidate in
                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(candidate.park.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                Text("\(Int(candidate.metres.rounded())) m from where \(friend.displayName) marked it · \(candidate.park.visitCount) \(candidate.park.visitCount == 1 ? "visit" : "visits")")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)

                                HStack(spacing: 10) {
                                    Button("Preview") { previewing = candidate.park }
                                        .buttonStyle(.bordered)
                                    Button("This one") {
                                        resolved[row.identifier] = candidate.park
                                        disambiguating = nil
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(Theme.fern)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Which one?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { disambiguating = nil }
                }
            }
        }
    }

    // MARK: - Actions

    private func toggle(_ row: AdoptableExclusion) {
        guard row.canBeSelected else { return }
        if selected.contains(row.identifier) {
            selected.remove(row.identifier)
        } else {
            selected.insert(row.identifier)
        }
    }

    private func open(_ row: AdoptableExclusion) {
        if case .ambiguous = row.match {
            disambiguating = row
            return
        }
        if let park = row.park {
            previewing = park
            return
        }
        // Nothing local to preview: an undiscovered place is only a name and a coordinate.
        disambiguating = nil
    }

    /// Records the rejection, and deletes the local park when there is one.
    ///
    /// Both halves matter and they are already paired inside `ParkDiscoveryService.exclude`:
    /// deleting without recording is undone by the next sweep, and recording without
    /// deleting leaves the thing on screen. A place the user hasn't discovered yet has
    /// nothing to delete, so only the record is written — which still stops it being filed.
    private func apply() {
        let rowsToApply = selectedRows
        for row in rowsToApply {
            if let park = row.park {
                services.discovery?.exclude(park)
            } else {
                guard !alreadyExcluded.contains(where: { $0.identifier == row.identifier }) else { continue }
                modelContext.insert(ExcludedPlace(
                    identifier: row.identifier,
                    name: row.name,
                    latitude: row.latitude,
                    longitude: row.longitude
                ))
            }
        }
        try? modelContext.save()
        selected = []
        resolved = [:]
        dismiss()
    }
}

/// One row of the adoption list, split out so it can be rendered and measured on its own.
///
/// Its inputs are plain values — no store, no services, no navigation — which is what lets
/// `AdoptExclusionsRenderTests` photograph it and check that a destructive row actually
/// looks destructive. The full sheet cannot be rendered that way: `ImageRenderer` gives up
/// on a `NavigationStack` with toolbars and draws a placeholder instead.
struct AdoptExclusionRow: View {
    let row: AdoptableExclusion
    let isSelected: Bool
    let onToggle: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(row.canBeSelected ? Theme.fern : Theme.textSecondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(!row.canBeSelected)
            .accessibilityLabel(row.name)
            .accessibilityValue(isSelected ? "Selected" : "Not selected")

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.leading)

                    Text(row.matchDescription)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)

                    if let cost = row.costDescription {
                        Label(cost, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.sunset)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary.opacity(0.5))
        }
    }
}
