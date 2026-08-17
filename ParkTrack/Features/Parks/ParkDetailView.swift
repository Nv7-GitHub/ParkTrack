import AVKit
import CoreLocation
import MapKit
import SwiftData
import SwiftUI
import UIKit

/// Everything known about a single park: where it is, how the user's relationship with it
/// has gone, and every visit they've logged.
///
/// The screen is a `List` rather than a `ScrollView` so visit rows get native swipe
/// actions; the hero simply lives in a full-bleed first row.
struct ParkDetailView: View {
    let park: Park

    @Environment(\.modelContext) private var modelContext
    @Environment(LocationProvider.self) private var location

    @State private var isLogging = false
    @State private var editingVisit: Visit?
    @State private var visitPendingDeletion: Visit?
    @State private var viewer: MediaViewerRequest?

    private var origin: CLLocation? { location.currentLocation }

    private var distanceText: String? {
        guard let origin else { return nil }
        return Format.distance(park.distance(from: origin))
    }

    private var visits: [Visit] { park.sortedVisits }

    var body: some View {
        List {
            Section {
                hero
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                statGrid
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                actions
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 12, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                if visits.isEmpty {
                    EmptyStateView(
                        systemImage: "figure.walk",
                        title: "No visits yet",
                        message: "Log your first trip to \(park.name) and it'll show up here with photos, notes and everything else.",
                        actionTitle: "Log Visit",
                        action: { isLogging = true }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(visits, id: \.identifier) { visit in
                        VisitHistoryRow(visit: visit) { items, index in
                            viewer = MediaViewerRequest(items: items, index: index)
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                visitPendingDeletion = visit
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                editingVisit = visit
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(Theme.sky)
                        }
                    }
                }
            } header: {
                Text(visits.isEmpty ? "Visit history" : "Visit history · \(visits.count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .textCase(nil)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle(park.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    toggleWishlist()
                } label: {
                    Image(systemName: park.isWishlisted ? "bookmark.fill" : "bookmark")
                }
                .accessibilityLabel(park.isWishlisted ? "Remove from wishlist" : "Add to wishlist")
            }
        }
        .sheet(isPresented: $isLogging) {
            LogVisitSheet(park: park)
        }
        .sheet(item: $editingVisit) { visit in
            LogVisitSheet(park: park, editing: visit)
        }
        .fullScreenCover(item: $viewer) { request in
            ParkMediaViewer(items: request.items, startIndex: request.index)
        }
        .confirmationDialog(
            "Delete this visit?",
            isPresented: Binding(
                get: { visitPendingDeletion != nil },
                set: { if !$0 { visitPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Visit", role: .destructive) { confirmDelete() }
            Button("Keep", role: .cancel) { visitPendingDeletion = nil }
        } message: {
            Text("Its notes and photos will be removed too. This can't be undone.")
        }
    }

    // MARK: Hero

    private var hero: some View {
        ZStack(alignment: .bottom) {
            Map(
                initialPosition: .region(
                    MKCoordinateRegion(center: park.coordinate, latitudinalMeters: 900, longitudinalMeters: 900)
                ),
                interactionModes: []
            ) {
                Marker(park.name, systemImage: "tree.fill", coordinate: park.coordinate)
                    .tint(Theme.fern)
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .including([.park, .nationalPark])))
            .allowsHitTesting(false)
            .frame(height: 280)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: park.isVisited ? "checkmark.seal.fill" : "circle.dashed")
                        .foregroundStyle(park.isVisited ? Theme.fern : Theme.textSecondary)
                    Text(park.isVisited ? "Visited" : "Not visited yet")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(park.isVisited ? Theme.fern : Theme.textSecondary)
                    if park.isWishlisted {
                        Pill(text: "Wishlist", systemImage: "bookmark.fill", tint: Theme.sunset)
                    }
                }

                Text(park.name)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)

                HStack(spacing: 6) {
                    if let region = park.regionLabel {
                        Text(region)
                    }
                    if park.regionLabel != nil, distanceText != nil {
                        Text("·")
                    }
                    if let distanceText {
                        Text("\(distanceText) away").monospacedDigit()
                    }
                }
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Stats + actions

    private var statGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            StatTile(
                value: "\(park.visitCount)",
                label: park.visitCount == 1 ? "Visit" : "Visits",
                systemImage: "figure.walk",
                tint: Theme.fern
            )
            StatTile(
                value: park.averageRating.map { String(format: "%.1f", $0) } ?? "—",
                label: "Average rating",
                systemImage: "star.fill",
                tint: Theme.sunset
            )
            StatTile(
                value: park.firstVisitDate.map(Format.date) ?? "—",
                label: "First visit",
                systemImage: "flag.fill",
                tint: Theme.sky
            )
            StatTile(
                value: park.lastVisitDate.map(Format.relative) ?? "—",
                label: "Last visit",
                systemImage: "clock.fill",
                tint: Theme.moss
            )
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                isLogging = true
            } label: {
                Label("Log Visit", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)

            HStack(spacing: 10) {
                Button {
                    toggleWishlist()
                } label: {
                    Label(park.isWishlisted ? "Saved" : "Wishlist", systemImage: park.isWishlisted ? "bookmark.fill" : "bookmark")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .tint(Theme.sunset)

                Button {
                    openDirections()
                } label: {
                    Label("Directions", systemImage: "arrow.triangle.turn.up.right.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .tint(Theme.sky)

                ShareLink(item: shareURL, subject: Text(park.name), message: Text(shareMessage)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .tint(Theme.moss)
            }
            .labelStyle(.iconOnly)
            .font(.title3)
        }
    }

    private var shareURL: URL {
        var components = URLComponents(string: "https://maps.apple.com/")!
        components.queryItems = [
            URLQueryItem(name: "ll", value: "\(park.latitude),\(park.longitude)"),
            URLQueryItem(name: "q", value: park.name)
        ]
        return components.url ?? URL(string: "https://maps.apple.com/")!
    }

    private var shareMessage: String {
        if let region = park.regionLabel {
            return "\(park.name) in \(region)"
        }
        return park.name
    }

    // MARK: Mutations

    private func toggleWishlist() {
        withAnimation(.smooth) { park.isWishlisted.toggle() }
        try? modelContext.save()
    }

    private func openDirections() {
        let placemark = MKPlacemark(coordinate: park.coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = park.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault])
    }

    private func confirmDelete() {
        guard let visit = visitPendingDeletion else { return }
        visitPendingDeletion = nil
        withAnimation(.smooth) { modelContext.delete(visit) }
        try? modelContext.save()
    }
}

/// A request to open the full-screen media viewer, carried as one value so the
/// `fullScreenCover(item:)` presentation stays atomic.
private struct MediaViewerRequest: Identifiable {
    let id = UUID()
    let items: [MediaItem]
    let index: Int
}

/// One logged visit, with every detail the user captured.
private struct VisitHistoryRow: View {
    let visit: Visit
    let onSelectMedia: ([MediaItem], Int) -> Void

    private var media: [MediaItem] { visit.sortedMedia }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(visit.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(visit.date.formatted(.dateTime.hour().minute()))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 8)
                    if visit.rating > 0 {
                        HStack(spacing: 2) {
                            ForEach(1...5, id: \.self) { star in
                                Image(systemName: star <= visit.rating ? "star.fill" : "star")
                                    .font(.caption2)
                                    .foregroundStyle(star <= visit.rating ? Theme.sunset : Theme.separator)
                            }
                        }
                        .accessibilityLabel("Rated \(visit.rating) out of 5")
                    }
                }

                let facts = factPills
                if !facts.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(facts, id: \.text) { fact in
                            Pill(text: fact.text, systemImage: fact.icon, tint: fact.tint)
                        }
                    }
                }

                if !visit.notes.isEmpty {
                    Text(visit.notes)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !media.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(media.enumerated()), id: \.element.identifier) { index, item in
                                Button {
                                    onSelectMedia(media, index)
                                } label: {
                                    MediaThumbnail(item: item, size: 92)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private struct Fact {
        let text: String
        let icon: String
        let tint: Color
    }

    private var factPills: [Fact] {
        var facts: [Fact] = []
        if let minutes = visit.durationMinutes {
            facts.append(Fact(text: Format.duration(minutes: minutes), icon: "clock", tint: Theme.sky))
        }
        if !visit.companions.isEmpty {
            facts.append(Fact(text: visit.companions, icon: "person.2.fill", tint: Theme.moss))
        }
        if let weather = visit.weatherSummary, !weather.isEmpty {
            facts.append(Fact(text: weather, icon: "cloud.sun.fill", tint: Theme.bark))
        }
        return facts
    }
}

/// Full-screen, swipe-through media. Videos are written to a temporary file because
/// `AVPlayer` needs a URL, not the bytes SwiftData hands back.
struct ParkMediaViewer: View {
    let items: [MediaItem]
    let startIndex: Int

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int

    init(items: [MediaItem], startIndex: Int) {
        self.items = items
        self.startIndex = startIndex
        _index = State(initialValue: startIndex)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.element.identifier) { offset, item in
                    MediaPage(item: item, isCurrent: offset == index)
                        .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: items.count > 1 ? .always : .never))
            .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(16)
            .accessibilityLabel("Close")
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
    }
}

private struct MediaPage: View {
    let item: MediaItem
    let isCurrent: Bool

    @State private var player: AVPlayer?
    @State private var videoURL: URL?

    var body: some View {
        Group {
            if item.isVideo {
                if let player {
                    VideoPlayer(player: player)
                        .onChange(of: isCurrent) { _, current in
                            if current { player.play() } else { player.pause() }
                        }
                } else {
                    ProgressView().tint(.white)
                }
            } else if let data = item.data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("Photo")
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await prepareVideo() }
        .onDisappear {
            player?.pause()
            if let videoURL { try? FileManager.default.removeItem(at: videoURL) }
        }
    }

    private func prepareVideo() async {
        guard item.isVideo, player == nil, let data = item.data else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("visit-\(item.identifier.uuidString)")
            .appendingPathExtension("mp4")
        if !FileManager.default.fileExists(atPath: url.path) {
            guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        }
        videoURL = url
        let created = AVPlayer(url: url)
        player = created
        if isCurrent { created.play() }
    }
}
