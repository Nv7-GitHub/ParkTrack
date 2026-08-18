import SwiftUI
import SwiftData

/// Review and remove things that were filed as parks but are not.
///
/// Nothing is deleted without being chosen. Entries with visits logged against them start
/// unselected and say so, because deleting one throws away a record of somewhere the user
/// says they went — which is worse than leaving a café in the list.
///
/// Removing one is a plain delete, and that is enough: everything here already fails the
/// test a search result has to pass, so nothing will file it again. Only somewhere the map
/// insists is a park needs striking off by name — see `ExcludedPlace`.
struct SuspiciousParksSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ServiceHub.self) private var services
    @Query private var parks: [Park]

    @State private var selected: Set<String> = []
    @State private var hasPreselected = false

    private var suspects: [Park] {
        ParkAudit.suspicious(parks).sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            Group {
                if suspects.isEmpty {
                    EmptyStateView(
                        systemImage: "checkmark.seal",
                        title: "Nothing out of place",
                        message: "Every entry in your catalogue looks like a park."
                    )
                } else {
                    List {
                        Section {
                            ForEach(suspects, id: \.identifier) { park in
                                row(for: park)
                            }
                        } header: {
                            Text("\(suspects.count) look wrong")
                        } footer: {
                            Text("These came from map results that the map doesn't list as parks, so removing one is the end of it — searching this area again won't bring it back. Anything with visits logged against it is left unselected, because removing it would delete those visits too.")
                        }
                    }
                }
            }
            .navigationTitle("Tidy up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Remove \(selected.count)", role: .destructive, action: deleteSelected)
                        .disabled(selected.isEmpty)
                }
            }
            .onAppear(perform: preselect)
        }
    }

    private func row(for park: Park) -> some View {
        Button {
            toggle(park)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected.contains(park.identifier) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected.contains(park.identifier) ? Theme.sunset : Theme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(park.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                    HStack(spacing: 6) {
                        Text(ParkAudit.reason(for: park))
                        if park.visitCount > 0 {
                            Text("· \(park.visitCount) visit\(park.visitCount == 1 ? "" : "s") logged")
                                .foregroundStyle(Theme.sunset)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 8)
            }
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ park: Park) {
        if selected.contains(park.identifier) {
            selected.remove(park.identifier)
        } else {
            selected.insert(park.identifier)
        }
    }

    /// Everything without visits starts selected: that is the safe bulk of it, and the user
    /// can still uncheck anything they meant to keep.
    private func preselect() {
        guard !hasPreselected else { return }
        hasPreselected = true
        selected = Set(suspects.filter { $0.visitCount == 0 }.map(\.identifier))
    }

    /// Deleted, not struck off.
    ///
    /// Everything on this list fails the test discovery applies to a search result — that is
    /// what put it here — so no sweep will ever file it again and there is nothing to
    /// remember. Recording one anyway filled the "not parks" list with ninety cafés and
    /// shops nobody had made a judgement about, and buried the handful of real decisions in
    /// it. Striking a place off is for the other case: somewhere the map insists is a park
    /// and the user says is not. See `ParkDetailView`.
    private func deleteSelected() {
        for park in suspects where selected.contains(park.identifier) {
            modelContext.delete(park)
        }
        try? modelContext.save()
        // Every indexed place that counted one of these is now claiming a total that
        // includes it. Recounting is free — it reads the store, not the map — so it happens
        // here rather than waiting for someone to re-index.
        services.regionIndexer?.recountIndexedRegions()
        selected = []
    }
}
