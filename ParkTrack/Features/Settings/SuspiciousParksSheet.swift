import SwiftUI
import SwiftData

/// Review and remove things that were filed as parks but are not.
///
/// Nothing is deleted without being chosen. Entries with visits logged against them start
/// unselected and say so, because deleting one throws away a record of somewhere the user
/// says they went — which is worse than leaving a café in the list.
///
/// Removing one also strikes it off for good. The map has not changed its mind about what a
/// place is, so a plain delete lasts only until the next sweep passes over that ground and
/// files it again — which is what made tidying up feel like it had not worked. See
/// `ExcludedPlace`.
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
                            Text("These came from map results that the map doesn't list as parks. Removing one also stops it being added back the next time this area is searched; you can let it back in from Settings. Anything with visits logged against it is left unselected — removing it would delete those visits too.")
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

    private func deleteSelected() {
        for park in suspects where selected.contains(park.identifier) {
            if let discovery = services.discovery {
                discovery.exclude(park)
            } else {
                modelContext.delete(park)
            }
        }
        try? modelContext.save()
        selected = []
    }
}
