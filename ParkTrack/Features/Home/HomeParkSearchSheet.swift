import SwiftUI
import CoreLocation

/// Search-by-name sheet over `ParkDiscoveryService.searchParks`.
///
/// Typing is debounced and each keystroke cancels the previous request, so a fast typist
/// costs one map query rather than one per character. Nothing is written to the store until
/// a row is tapped.
struct HomeParkSearchSheet: View {
    let discovery: ParkDiscoveryService
    let near: CLLocationCoordinate2D?
    let onSelect: (Park) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [ParkCandidate] = []
    @State private var isSearching = false
    @State private var hasSearched = false

    private var origin: CLLocation? {
        near.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isSearching && results.isEmpty {
                    ProgressView("Searching…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty {
                    EmptyStateView(
                        systemImage: hasSearched ? "questionmark.circle" : "magnifyingglass",
                        title: hasSearched ? "No matches" : "Search for a park",
                        message: hasSearched
                            ? "Try a shorter name, or the name of the town it's in."
                            : "Type a park name. Results near you come first, but you can log a park anywhere."
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    List(results) { candidate in
                        Button {
                            select(candidate)
                        } label: {
                            row(candidate)
                        }
                        .listRowBackground(Theme.surfaceRaised)
                    }
                    .listStyle(.plain)
                }
            }
            .background(Theme.background)
            .navigationTitle("Find a park")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Park name")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task(id: query) {
                await search()
            }
        }
    }

    private func row(_ candidate: ParkCandidate) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "tree.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.moss)
                .frame(width: 34, height: 34)
                .background(Theme.moss.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                if let address = candidate.addressLine {
                    Text(address)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if let origin {
                let distance = CLLocation(
                    latitude: candidate.coordinate.latitude,
                    longitude: candidate.coordinate.longitude
                ).distance(from: origin)
                Text(Format.distance(distance))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func select(_ candidate: ParkCandidate) {
        let park = discovery.park(for: candidate)
        onSelect(park)
        dismiss()
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            hasSearched = false
            return
        }
        try? await Task.sleep(for: .milliseconds(320))
        guard !Task.isCancelled else { return }

        isSearching = true
        let found = await discovery.searchParks(named: trimmed, near: near)
        guard !Task.isCancelled else { return }
        isSearching = false
        hasSearched = true
        results = found
    }
}
