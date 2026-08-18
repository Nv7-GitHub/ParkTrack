import SwiftUI
import SwiftData

/// Everywhere the user has said is not a park, and the way back.
///
/// An exclusion is the only thing in the app that overrules the map, so it has to be legible
/// and reversible. Letting a place back in does not add it again by itself — the next sweep
/// over that ground will find it, exactly as it did the first time.
struct ExcludedPlacesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ServiceHub.self) private var services
    @Query(sort: \ExcludedPlace.name) private var excluded: [ExcludedPlace]

    @State private var isConfirmingClear = false

    var body: some View {
        NavigationStack {
            Group {
                if excluded.isEmpty {
                    EmptyStateView(
                        systemImage: "checkmark.seal",
                        title: "Nothing struck off",
                        message: "Places you remove as \"not a park\" are listed here, so you can let them back in."
                    )
                } else {
                    List {
                        Section {
                            ForEach(excluded, id: \.identifier) { place in
                                row(for: place)
                            }
                        } header: {
                            Text("\(excluded.count) struck off")
                        } footer: {
                            Text("Searching an area will not add these back. Letting one back in doesn't restore it on its own — the next search of that area will find it again.\n\nOnly places the map insists are parks need to be on this list. Tidying up the catalogue used to add everything it removed, which filled this with cafés and shops that would never have been added back anyway; those are safe to clear.")
                        }
                    }
                }
            }
            .navigationTitle("Not parks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear all", role: .destructive) { isConfirmingClear = true }
                        .disabled(excluded.isEmpty)
                }
            }
            .confirmationDialog(
                "Clear the whole list?",
                isPresented: $isConfirmingClear,
                titleVisibility: .visible
            ) {
                Button("Clear \(excluded.count)", role: .destructive, action: clearAll)
                Button("Keep", role: .cancel) {}
            } message: {
                Text("Nothing is added back by this. Anything the map doesn't call a park stays out on its own; only somewhere the map insists is a park could reappear, and you can strike it off again from its own page.")
            }
        }
    }

    private func clearAll() {
        for place in excluded { modelContext.delete(place) }
        try? modelContext.save()
    }

    private func row(for place: ExcludedPlace) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Text("Struck off \(Format.relative(place.excludedAt))")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            Button("Let back in") {
                services.discovery?.readmit(place)
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .tint(Theme.accent)
        }
    }
}
