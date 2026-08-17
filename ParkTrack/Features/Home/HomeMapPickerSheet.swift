import SwiftUI
import SwiftData
import MapKit
import CoreLocation

/// Map-based picker used by two Home actions: choosing a park to log, and dropping the
/// home pin the completion rings measure from.
///
/// The same map serves both because the interaction is nearly identical — the only
/// difference is whether the answer is a marker you tapped or the point under the
/// crosshair. Parks are drawn from the cache and topped up on demand rather than searched
/// continuously, which keeps panning free of map requests.
struct HomeMapPickerSheet: View {
    enum Purpose: String, Identifiable {
        case logVisit
        case setHome

        var id: String { rawValue }
    }

    let purpose: Purpose
    let discovery: ParkDiscoveryService
    let start: CLLocationCoordinate2D?
    let onPickPark: (Park) -> Void
    let onPickCoordinate: (CLLocationCoordinate2D) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(LocationProvider.self) private var location
    @Query private var parks: [Park]

    @State private var camera: MapCameraPosition
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var selection: Park?
    @State private var isDiscovering = false

    init(
        purpose: Purpose,
        discovery: ParkDiscoveryService,
        start: CLLocationCoordinate2D?,
        onPickPark: @escaping (Park) -> Void,
        onPickCoordinate: @escaping (CLLocationCoordinate2D) -> Void
    ) {
        self.purpose = purpose
        self.discovery = discovery
        self.start = start
        self.onPickPark = onPickPark
        self.onPickCoordinate = onPickCoordinate
        if let start {
            _camera = State(initialValue: .region(MKCoordinateRegion(
                center: start,
                latitudinalMeters: 6_000,
                longitudinalMeters: 6_000
            )))
        } else {
            _camera = State(initialValue: .userLocation(fallback: .automatic))
        }
    }

    private var visibleParks: [Park] {
        guard let region = visibleRegion else { return Array(parks.prefix(120)) }
        return parks.filter { contains(region, $0.coordinate) }.prefix(150).map { $0 }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                map
                if purpose == .setHome {
                    crosshair
                }
                controls
            }
            .navigationTitle(purpose == .setHome ? "Set home" : "Pick a park")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await discoverHere() }
                    } label: {
                        if isDiscovering {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Search this area", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isDiscovering)
                }
            }
        }
    }

    private var map: some View {
        Map(position: $camera) {
            if location.isAuthorized {
                UserAnnotation()
            }
            ForEach(visibleParks) { park in
                Annotation(park.name, coordinate: park.coordinate, anchor: .bottom) {
                    pin(for: park)
                }
                .annotationTitles(purpose == .setHome ? .hidden : .automatic)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .including([.park, .nationalPark])))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleRegion = context.region
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private func pin(for park: Park) -> some View {
        let isSelected = selection?.identifier == park.identifier
        return Image(systemName: park.isVisited ? "checkmark.circle.fill" : "tree.fill")
            .font(.system(size: isSelected ? 17 : 13, weight: .bold))
            .foregroundStyle(.white)
            .padding(isSelected ? 9 : 7)
            .background(park.isVisited ? Theme.fern : Theme.sky, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 2))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .animation(.smooth(duration: 0.25), value: isSelected)
            .onTapGesture {
                guard purpose == .logVisit else { return }
                selection = park
            }
            .accessibilityLabel(park.name)
            .accessibilityAddTraits(.isButton)
    }

    private var crosshair: some View {
        Image(systemName: "plus.viewfinder")
            .font(.system(size: 34, weight: .light))
            .foregroundStyle(Theme.accent)
            .padding(10)
            .background(.ultraThinMaterial, in: Circle())
            .frame(maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 10) {
            if purpose == .setHome {
                actionCard(
                    title: "Centre the map on home",
                    detail: "Rings and suggestions are measured from this point.",
                    buttonTitle: "Set home here"
                ) {
                    let center = visibleRegion?.center ?? start ?? location.currentLocation?.coordinate
                    guard let center else { return }
                    onPickCoordinate(center)
                    dismiss()
                }
            } else if let selection {
                actionCard(
                    title: selection.name,
                    detail: selection.regionLabel ?? "Tap another pin to change your pick.",
                    buttonTitle: "Log a visit here"
                ) {
                    onPickPark(selection)
                    dismiss()
                }
            } else {
                hint
            }
        }
        .padding(16)
    }

    private var hint: some View {
        Text(parks.isEmpty
             ? "No parks cached yet — tap Search this area to find some."
             : "Tap a pin to pick that park.")
            .font(.footnote)
            .foregroundStyle(Theme.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private func actionCard(
        title: String,
        detail: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
    }

    private func discoverHere() async {
        guard let region = visibleRegion ?? start.map({
            MKCoordinateRegion(center: $0, latitudinalMeters: 6_000, longitudinalMeters: 6_000)
        }) else { return }
        isDiscovering = true
        await discovery.discoverParks(in: region)
        isDiscovering = false
    }

    private func contains(_ region: MKCoordinateRegion, _ coordinate: CLLocationCoordinate2D) -> Bool {
        let latitudeDelta = abs(coordinate.latitude - region.center.latitude)
        let longitudeDelta = abs(coordinate.longitude - region.center.longitude)
        return latitudeDelta <= region.span.latitudeDelta / 2
            && longitudeDelta <= region.span.longitudeDelta / 2
    }
}
