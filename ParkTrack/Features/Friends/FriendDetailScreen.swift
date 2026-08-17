import SwiftUI
import MapKit

/// A friend's profile: the same stat tiles you see for yourself, everywhere they've
/// been, and the visits behind those numbers.
///
/// Deliberately symmetric with the user's own stats screen — the point of adding
/// someone is to read their year the way you read your own.
struct FriendDetailScreen: View {
    let friend: Friend
    let social: SocialService?

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingRemove = false

    private var visits: [FriendVisit] {
        (friend.visits ?? []).sorted { $0.date > $1.date }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.sectionSpacing) {
                header
                statTiles
                if let region = mapRegion {
                    mapCard(region: region)
                }
                visitList
                removeButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .background(Theme.background)
        .navigationTitle(friend.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Remove \(friend.displayName)?",
            isPresented: $isConfirmingRemove,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                social?.removeFriend(friend)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their stats and shared visits are deleted from this device. You can add them again any time with their code.")
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 12) {
            Text(initials)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(.white.opacity(0.18), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1))
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(friend.displayName)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text(friend.friendCode)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .monospaced()
                    .foregroundStyle(.white.opacity(0.85))
            }
            Text(syncLabel)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(Theme.heroGradient, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var statTiles: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
            spacing: 12
        ) {
            StatTile(value: "\(friend.totalParks)", label: "Parks visited", systemImage: "tree.fill")
            StatTile(value: "\(friend.totalVisits)", label: "Total visits", systemImage: "figure.walk", tint: Theme.moss)
            StatTile(value: "\(friend.citiesCount)", label: "Cities", systemImage: "building.2.fill", tint: Theme.sky)
            StatTile(value: streakValue, label: "Current streak", systemImage: "flame.fill", tint: Theme.sunset)
            StatTile(value: "\(friend.parksThisMonth)", label: "New this month", systemImage: "calendar", tint: Theme.fern)
            StatTile(value: lastVisitValue, label: "Last visit", systemImage: "clock", tint: Theme.bark)
        }
    }

    private func mapCard(region: MKCoordinateRegion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Where they've been", subtitle: "\(visits.count) shared visit\(visits.count == 1 ? "" : "s")")
            Map(initialPosition: .region(region), interactionModes: []) {
                ForEach(visits) { visit in
                    Marker(visit.parkName, systemImage: "tree.fill", coordinate: visit.coordinate)
                        .tint(Theme.accent)
                }
            }
            .frame(height: 230)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                Text(Format.parkCount(uniqueParkNames.count))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(12)
            }
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.separator, lineWidth: 0.5)
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Map of \(friend.displayName)'s shared visits")
        }
    }

    private var visitList: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Their visits")
            if visits.isEmpty {
                Card {
                    EmptyStateView(
                        systemImage: "leaf",
                        title: "Nothing shared yet",
                        message: "\(friend.displayName) hasn't shared any visits. Pull to refresh on the Friends tab to check again."
                    )
                }
            } else {
                ForEach(visits) { visit in
                    FriendVisitRow(visit: visit, showsFriendName: false)
                }
            }
        }
    }

    private var removeButton: some View {
        Button(role: .destructive) {
            isConfirmingRemove = true
        } label: {
            Label("Remove friend", systemImage: "person.badge.minus")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .disabled(social == nil)
        .padding(.top, 8)
    }

    // MARK: - Derived values

    private var initials: String {
        let letters = friend.displayName
            .split(whereSeparator: { $0 == " " || $0 == "-" })
            .prefix(2)
            .compactMap { $0.first }
        let text = String(letters).uppercased()
        return text.isEmpty ? String(friend.friendCode.prefix(2)) : text
    }

    private var uniqueParkNames: Set<String> {
        Set(visits.map(\.parkName))
    }

    private var streakValue: String {
        friend.currentStreakWeeks == 1 ? "1 wk" : "\(friend.currentStreakWeeks) wks"
    }

    private var lastVisitValue: String {
        guard let last = visits.first?.date else { return "—" }
        return Format.relative(last)
    }

    private var syncLabel: String {
        guard let synced = friend.lastSyncedAt else { return "Not synced yet" }
        return "Synced \(Format.relative(synced))"
    }

    /// Bounding box of everything they've shared, padded so pins aren't glued to the
    /// edge, with a floor so a single visit doesn't zoom to street level.
    private var mapRegion: MKCoordinateRegion? {
        let coordinates = visits.map(\.coordinate)
        guard !coordinates.isEmpty else { return nil }

        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        guard let minLat = latitudes.min(), let maxLat = latitudes.max(),
              let minLon = longitudes.min(), let maxLon = longitudes.max() else { return nil }

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2,
                longitude: (minLon + maxLon) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * 1.5, 0.03),
                longitudeDelta: max((maxLon - minLon) * 1.5, 0.03)
            )
        )
    }
}
