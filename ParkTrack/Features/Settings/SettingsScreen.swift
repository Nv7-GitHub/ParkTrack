import SwiftUI
import SwiftData
import UIKit
import CoreLocation
import MapKit
import UniformTypeIdentifiers

/// Everything the app keeps about the person using it, in one place: who they are to
/// friends, where "home" is for the radius rings, and what happens to their data.
///
/// The destructive and irreversible actions live here rather than being scattered
/// through the app, and each one says plainly what it will do before it does it.
struct SettingsScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(LocationProvider.self) private var location
    @Environment(AppSettings.self) private var settings
    @Environment(ServiceHub.self) private var services

    @Query private var parks: [Park]
    @State private var isReviewingSuspects = false
    @State private var isFixingMarkedVisits = false
    /// Fetched in full because deleting them and reacting to their arrival both need the
    /// objects, not just a count.
    @Query private var visits: [Visit]
    @Query private var regionIndexes: [RegionIndex]

    // The data card's three figures each walked the whole catalogue on every body
    // evaluation — and the suspect check runs a category match per park — so scrolling this
    // sheet re-audited the store on every frame.
    @State private var auditCache = DerivedCache<AuditCounts>()
    /// Bumped by anything that changes what the audit would find without changing how many
    /// parks or visits there are — resolving regions fills in cities, which is exactly that.
    @State private var auditRevision = 0

    struct AuditCounts {
        let suspicious: Int
        let unresolved: Int
    }

    /// Dated visits carrying nothing but the fact of the visit — the shape a park marked
    /// visited used to be written in, before undated visits existed.
    private var markedVisitCount: Int {
        var count = 0
        for visit in visits where !visit.isUndated && visit.park != nil && visit.hasNoDetails {
            count += 1
        }
        return count
    }

    /// Reverse-geocoded names, per place, so a saved point reads as somewhere rather than
    /// as a pair of numbers.
    @State private var placeNames: [SavedPlaceKind: String] = [:]
    @State private var resolvingPlace: SavedPlaceKind?
    @State private var mediaBytes: Int64 = 0

    @State private var pickingPlace: SavedPlaceKind?
    @State private var isConfirmingDeletion = false
    @State private var isImporting = false

    @State private var activity: String?
    @State private var status: String?
    @State private var errorMessage: String?

    @State private var exportURL: URL?

    private var discovery: ParkDiscoveryService? { services.discovery }

    init() {}

    /// Entries that were filed as parks from a non-park search result, back when tapping any
    /// result added one — counted alongside the unplaced ones, in one pass.
    private var auditCounts: AuditCounts {
        auditCache.value(
            for: StatsSignature(
                parkCount: parks.count,
                visitCount: visitCount,
                extra: [Double(auditRevision)]
            )
        ) {
            var suspicious = 0
            var unresolved = 0
            for park in parks {
                if ParkAudit.isSuspicious(park) { suspicious += 1 }
                if park.regionResolvedAt == nil { unresolved += 1 }
            }
            return AuditCounts(suspicious: suspicious, unresolved: unresolved)
        }
    }

    private var suspiciousCount: Int { auditCounts.suspicious }

    /// Counted by the store rather than by fetching and materialising every visit, which is
    /// all the old `@Query` was for.
    private var visitCount: Int { modelContext.visitCount() }

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.sectionSpacing) {
                    profileCard(settings: settings)
                    placesCard()
                    radiusCard(settings: settings)
                    dataCard()
                    backupCard()
                    aboutCard()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .background(Theme.background)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: isReviewingSuspects) { _, isOpen in
                // Coming back from the review, some of those entries may be gone.
                if !isOpen { auditRevision += 1 }
            }
            .sheet(isPresented: $isFixingMarkedVisits) {
                FixMarkedVisitsSheet()
            }
            .sheet(isPresented: $isReviewingSuspects) {
            SuspiciousParksSheet()
        }
        .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $pickingPlace) { kind in
                SettingsPlaceLocationPicker(
                    kind: kind,
                    initialCoordinate: settings.coordinate(for: kind) ?? location.currentLocation?.coordinate,
                    initialLabel: settings.label(for: kind)
                ) { coordinate, label in
                    settings.setCoordinate(coordinate, for: kind)
                    settings.setLabel(label, for: kind)
                    Task { await resolvePlaceName(for: kind) }
                }
            }
            .sheet(isPresented: $isConfirmingDeletion) {
                SettingsDeleteConfirmation(visitCount: visits.count) {
                    deleteAllVisits()
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
        }
        .task {
            mediaBytes = DataExport.mediaBytesOnDisk(context: modelContext)
            refreshExportFile()
            // Sequentially: the geocoder is rate-limited, and three lookups fired at once is
            // how you get two of them back empty.
            for kind in settings.savedPlaces {
                await resolvePlaceName(for: kind)
            }
        }
        .onChange(of: parks.count) { refreshExportFile() }
        .onChange(of: visits.count) { refreshExportFile() }
    }

    // MARK: - Profile

    private func profileCard(settings: AppSettings) -> some View {
        @Bindable var settings = settings

        return Card {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader("Profile", subtitle: "How you appear to friends")

                VStack(alignment: .leading, spacing: 6) {
                    Text("Display name")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                    TextField("Your name", text: $settings.displayName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.tightCornerRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.tightCornerRadius, style: .continuous)
                                .strokeBorder(Theme.separator, lineWidth: 0.5)
                        )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Your friend code")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)

                    HStack(spacing: 12) {
                        Text(settings.friendCode)
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .kerning(4)
                            .foregroundStyle(Theme.textPrimary)
                            .accessibilityLabel("Your friend code")
                            .accessibilityValue(settings.friendCode.map { String($0) }.joined(separator: " "))

                        Spacer(minLength: 8)

                        Button {
                            UIPasteboard.general.string = settings.friendCode
                            show(status: "Friend code copied.")
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .labelStyle(.iconOnly)
                                .font(.system(size: 17, weight: .semibold))
                                .frame(width: 40, height: 40)
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.accent)
                        .accessibilityLabel("Copy friend code")

                        ShareLink(item: shareText(for: settings)) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .labelStyle(.iconOnly)
                                .font(.system(size: 17, weight: .semibold))
                                .frame(width: 40, height: 40)
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.accent)
                        .accessibilityLabel("Share friend code")
                    }

                    Text("Friends add you with this code. It's the only thing they need.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func shareText(for settings: AppSettings) -> String {
        let name = settings.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let who = name.isEmpty ? "me" : name
        return "Add \(who) on ParkTrack with friend code \(settings.friendCode)."
    }

    // MARK: - Places

    /// Every place the rings can be measured from, and the only screen that adds or removes
    /// one. A place that isn't set says what it would be for rather than hiding.
    private func placesCard() -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(
                    "Your places",
                    subtitle: "Stats can measure how much you've explored around any of these"
                )

                VStack(spacing: 0) {
                    ForEach(SavedPlaceKind.allCases) { kind in
                        placeRow(kind)
                        if kind != SavedPlaceKind.allCases.last {
                            Divider().overlay(Theme.separator).padding(.vertical, 4)
                        }
                    }
                }

                if !location.isAuthorized {
                    Text("Location access is off, so ParkTrack can't read your current position.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Home is also the fallback centre for the rest of the app when there's no location fix.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func placeRow(_ kind: SavedPlaceKind) -> some View {
        let coordinate = settings.coordinate(for: kind)

        HStack(spacing: 12) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(coordinate == nil ? Theme.textSecondary : kind.tint)
                .frame(width: 32, height: 32)
                .background(
                    (coordinate == nil ? Theme.textSecondary : kind.tint).opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(settings.label(for: kind))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)

                if coordinate != nil {
                    HStack(spacing: 6) {
                        if resolvingPlace == kind { ProgressView().controlSize(.mini) }
                        Text(placeNames[kind] ?? coordinateDescription(for: kind))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                    }
                } else {
                    Text(kind.unsetMessage)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            Menu {
                Button("Choose on map", systemImage: "mappin.and.ellipse") {
                    pickingPlace = kind
                }
                Button("Use current location", systemImage: "location.fill") {
                    Task { await useCurrentLocation(for: kind) }
                }
                .disabled(!location.isAuthorized)
                if coordinate != nil {
                    Divider()
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        remove(kind)
                    }
                }
            } label: {
                Image(systemName: coordinate == nil ? "plus.circle.fill" : "ellipsis.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(coordinate == nil ? "Add \(kind.title)" : "Edit \(kind.title)")
        }
        .padding(.vertical, 6)
    }

    private func coordinateDescription(for kind: SavedPlaceKind) -> String {
        guard let coordinate = settings.coordinate(for: kind) else { return "" }
        return String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
    }

    private func remove(_ kind: SavedPlaceKind) {
        withAnimation(.smooth(duration: 0.25)) {
            settings.setCoordinate(nil, for: kind)
        }
        placeNames[kind] = nil
        show(status: "\(kind.title) removed.")
    }

    private func useCurrentLocation(for kind: SavedPlaceKind) async {
        activity = "Finding you…"
        defer { activity = nil }
        guard let fix = await location.resolveLocation() else {
            errorMessage = "Couldn't get a location fix. Try again outdoors or with Wi-Fi on."
            return
        }
        settings.setCoordinate(fix.coordinate, for: kind)
        await resolvePlaceName(for: kind)
        show(status: "\(kind.title) set to your current location.")
    }

    /// One-off reverse geocode. Park geocoding goes through `RegionResolver`'s throttled
    /// queue; this is a single user-triggered lookup, so it can go direct.
    private func resolvePlaceName(for kind: SavedPlaceKind) async {
        guard let coordinate = settings.coordinate(for: kind) else {
            placeNames[kind] = nil
            return
        }
        resolvingPlace = kind
        defer { resolvingPlace = nil }

        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(
            CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        )
        guard let placemark = placemarks?.first else { return }
        let parts = [placemark.locality ?? placemark.subAdministrativeArea, placemark.administrativeArea]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        placeNames[kind] = parts.isEmpty ? placemark.country : parts.joined(separator: ", ")
    }

    // MARK: - Radius

    private func radiusCard(settings: AppSettings) -> some View {
        @Bindable var settings = settings

        return Card {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader("Completion rings", subtitle: "How far out you're tracking")

                HStack(spacing: 8) {
                    ForEach(AppSettings.defaultRadiiMiles, id: \.self) { miles in
                        Pill(text: Format.miles(miles), systemImage: "circle.dashed")
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Fixed rings: 2.5, 5 and 10 miles")

                Text("The first three rings are fixed. The fourth is yours.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Custom ring")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(Format.miles(settings.customRadiusMiles))
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.accent)
                            .contentTransition(.numericText())
                            .animation(.smooth(duration: 0.3), value: settings.customRadiusMiles)
                    }

                    Slider(value: $settings.customRadiusMiles, in: 0.5...100, step: 0.5) {
                        Text("Custom radius")
                    } minimumValueLabel: {
                        Text("0.5").font(.caption2).foregroundStyle(Theme.textSecondary)
                    } maximumValueLabel: {
                        Text("100").font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
                    .tint(Theme.accent)
                    .accessibilityValue(Format.miles(settings.customRadiusMiles))

                    Stepper(value: $settings.customRadiusMiles, in: 0.5...100, step: 0.5) {
                        Text("Adjust by half a mile")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }

    // MARK: - Data

    private func dataCard() -> some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader("Data", subtitle: "What's stored on this device")

                HStack(spacing: 10) {
                    StatTile(value: "\(parks.count)", label: "Parks tracked", systemImage: "tree.fill")
                    StatTile(value: "\(visitCount)", label: "Visits logged", systemImage: "figure.walk", tint: Theme.sky)
                    StatTile(
                        value: DataExport.formatBytes(mediaBytes),
                        label: "Photos & video",
                        systemImage: "photo.stack",
                        tint: Theme.sunset
                    )
                }

                VStack(spacing: 10) {
                    Button {
                        Task { await rescanArea() }
                    } label: {
                        settingsRow(
                            title: "Rescan area for new parks",
                            detail: "Searches the map out to \(Format.miles(scanRadiusMiles)) around home",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .disabled(activity != nil || scanCentre == nil)

                    Button {
                        Task { await resolveRegions() }
                    } label: {
                        settingsRow(
                            title: "Resolve missing regions",
                            detail: unresolvedCount == 0
                                ? "Every park knows its city and state"
                                : "\(unresolvedCount) \(unresolvedCount == 1 ? "park needs" : "parks need") a city and state",
                            systemImage: "globe.americas"
                        )
                    }
                    .disabled(activity != nil || unresolvedCount == 0)

                    Button {
                        isReviewingSuspects = true
                    } label: {
                        settingsRow(
                            title: "Tidy up the catalogue",
                            detail: suspiciousCount == 0
                                ? "Nothing in your list looks out of place"
                                : "\(suspiciousCount) \(suspiciousCount == 1 ? "entry doesn't" : "entries don't") look like parks",
                            systemImage: "wand.and.sparkles"
                        )
                    }
                    .disabled(suspiciousCount == 0)

                    Menu {
                        Button("Indexed areas only · \(recheckCount(scoped: true))") {
                            Task { await recheckPlacements(scoped: true) }
                        }
                        .disabled(indexedScopes.isEmpty)
                        Button("Every park · \(recheckCount(scoped: false)), \(recheckMinutes) min") {
                            Task { await recheckPlacements(scoped: false) }
                        }
                    } label: {
                        settingsRow(
                            title: "Recheck park locations",
                            detail: recheckDetail,
                            systemImage: "mappin.and.ellipse",
                            tint: Theme.moss
                        )
                    }
                    .disabled(activity != nil || parks.isEmpty)

                    Button {
                        isFixingMarkedVisits = true
                    } label: {
                        settingsRow(
                            title: "Fix marked visits",
                            detail: markedVisitCount == 0
                                ? "No visits look like they were marked rather than logged"
                                : "\(markedVisitCount) dated \(markedVisitCount == 1 ? "visit has" : "visits have") no details — they may be marks, not logs",
                            systemImage: "calendar.badge.minus",
                            tint: Theme.sky
                        )
                    }

                    Button(role: .destructive) {
                        isConfirmingDeletion = true
                    } label: {
                        settingsRow(
                            title: "Delete all visits",
                            detail: "Removes every visit and its photos. Parks stay.",
                            systemImage: "trash",
                            tint: .red
                        )
                    }
                    .disabled(visits.isEmpty)
                }
                .buttonStyle(.plain)

                if let activity {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(activity)
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                if let status {
                    Label(status, systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.accent)
                        .transition(.opacity)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.sunset)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .animation(.smooth(duration: 0.25), value: status)
            .animation(.smooth(duration: 0.25), value: activity)
        }
    }

    private var unresolvedCount: Int { auditCounts.unresolved }

    /// `@Query` hands back a snapshot that only refreshes when the body re-runs, so
    /// before/after comparisons across an `await` have to ask the store directly.
    private func storedParkCount() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<Park>())) ?? parks.count
    }

    private func storedUnresolvedCount() -> Int {
        let descriptor = FetchDescriptor<Park>(predicate: #Predicate<Park> { $0.regionResolvedAt == nil })
        return (try? modelContext.fetchCount(descriptor)) ?? unresolvedCount
    }

    private var scanCentre: CLLocationCoordinate2D? {
        settings.homeCoordinate ?? location.currentLocation?.coordinate
    }

    private var scanRadiusMiles: Double {
        settings.radiiMiles.max() ?? 10
    }

    private func rescanArea() async {
        guard let discovery, let centre = scanCentre else {
            errorMessage = "Set a home location first so ParkTrack knows where to look."
            return
        }
        errorMessage = nil
        activity = "Searching the map…"
        defer { activity = nil }

        let before = storedParkCount()
        await discovery.discoverParks(around: centre, radiusMiles: scanRadiusMiles)

        if let failure = discovery.lastError {
            errorMessage = failure
            return
        }
        let added = max(0, storedParkCount() - before)
        auditRevision += 1
        show(status: added == 0 ? "No new parks found nearby." : "Found \(Format.parkCount(added)).")
    }

    /// Verifies where parks actually are, correcting any placed by inference.
    ///
    /// Parks with no placemark of their own borrow one from their neighbours, which is fast
    /// and usually right — but near a boundary with nothing on the far side of it, every
    /// neighbour can agree and every neighbour can be wrong. The Commonwealth Avenue Mall is
    /// in Boston, a kilometre across the Charles from Cambridge, and was being counted
    /// towards Cambridge.
    ///
    /// The geocoder answers about once a second, so this works through a batch at a time and
    /// says what it did. Run it again to continue.
    /// Only the places whose totals claim to be authoritative. Checking a whole catalogue
    /// means one geocode per park at about a second each — tens of minutes for a few
    /// thousand, and well into the geocoder's own limits — while the indexed places are
    /// usually a handful and are the only ones publishing a number.
    private var indexedScopes: Set<String> {
        Set(regionIndexes.filter(\.isIndexed).map(\.identifier))
    }

    private func recheckCount(scoped: Bool) -> Int {
        RegionResolver.shared.reverifiableParkCount(
            context: modelContext,
            within: scoped ? indexedScopes : nil
        )
    }

    /// The geocoder answers about once a second, which is the only thing that makes checking
    /// a whole catalogue a decision rather than a button.
    private var recheckMinutes: Int {
        max(1, Int((Double(recheckCount(scoped: false)) * 1.2 / 60).rounded()))
    }

    private var recheckDetail: String {
        "Moves any park filed under the wrong city. Indexed areas are the ones publishing a total"
    }

    private func recheckPlacements(scoped: Bool) async {
        errorMessage = nil
        activity = "Checking where parks are…"
        defer { activity = nil }

        let corrected = await RegionResolver.shared.reverifyRegions(
            context: modelContext,
            limit: 150,
            within: scoped ? indexedScopes : nil
        ) { checked, total in
            activity = "Checking park \(checked) of \(total)…"
        }

        auditRevision += 1
        show(status: corrected == 0
             ? "Every park checked was already in the right place."
             : "Moved \(Format.parkCount(corrected)) to the right city. Run it again to check more.")
    }

    private func resolveRegions() async {
        errorMessage = nil
        activity = "Looking up cities and states…"
        defer { activity = nil }

        let before = storedUnresolvedCount()
        await RegionResolver.shared.resolveMissingRegions(context: modelContext, limit: 60)
        let resolved = max(0, before - storedUnresolvedCount())
        auditRevision += 1
        show(status: resolved == 0
             ? "Nothing new could be resolved right now."
             : "Resolved \(Format.parkCount(resolved)).")
    }

    private func deleteAllVisits() {
        for visit in visits {
            modelContext.delete(visit)
        }
        try? modelContext.save()
        mediaBytes = DataExport.mediaBytesOnDisk(context: modelContext)
        refreshExportFile()
        show(status: "All visits deleted.")
    }

    // MARK: - Backup

    private func backupCard() -> some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader("Backup", subtitle: "A plain JSON file you keep")

                if let exportURL {
                    ShareLink(item: exportURL) {
                        settingsRow(
                            title: "Export everything",
                            detail: "\(Format.parkCount(parks.count)), \(visits.count) \(visits.count == 1 ? "visit" : "visits"), notes, ratings and wishlist",
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    settingsRow(
                        title: "Export everything",
                        detail: "Preparing the file…",
                        systemImage: "square.and.arrow.up"
                    )
                    .opacity(0.5)
                }

                Button {
                    isImporting = true
                } label: {
                    settingsRow(
                        title: "Import a backup",
                        detail: "Merges by park, so nothing gets duplicated",
                        systemImage: "square.and.arrow.down"
                    )
                }
                .buttonStyle(.plain)

                Text("Photos and video aren't included — they'd make the file enormous. Turn on iCloud sync to carry media between devices.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func refreshExportFile() {
        let payload = DataExport.makeBackup(
            parks: parks,
            displayName: settings.displayName,
            friendCode: settings.friendCode,
            home: settings.homeCoordinate,
            homeLabel: settings.homeLabel,
            customRadiusMiles: settings.customRadiusMiles
        )
        exportURL = try? DataExport.writeTemporaryFile(payload)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        errorMessage = nil
        do {
            guard let url = try result.get().first else { return }

            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

            guard let data = try? Data(contentsOf: url) else { throw BackupError.unreadableFile }
            let payload = try DataExport.decode(data)
            let summary = try DataExport.merge(payload, into: modelContext)

            refreshExportFile()
            show(status: summary.sentence)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - About

    private func aboutCard() -> some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader("About")

                VStack(spacing: 12) {
                    aboutRow(title: "Version", value: versionString)

                    aboutRow(
                        title: "iCloud sync",
                        value: PersistenceController.isCloudSyncActive ? "On" : "Off",
                        detail: PersistenceController.isCloudSyncActive
                            ? "Parks, visits and media sync to your other devices."
                            : "This build isn't signed for iCloud, so everything stays on this device."
                    )

                    aboutRow(
                        title: "Friend sync",
                        value: CloudKitAvailability.isUsable ? "Live" : "Sample data",
                        detail: CloudKitAvailability.isUsable
                            ? "Friend codes reach real people through iCloud."
                            : "Friends are simulated locally so the tab is explorable. Nothing you share leaves this device."
                    )
                }
            }
        }
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    private func aboutRow(title: String, value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Shared pieces

    private func settingsRow(title: String, detail: String, systemImage: String, tint: Color = Theme.accent) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(tint == Theme.accent ? Theme.textPrimary : tint)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary.opacity(0.6))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.tightCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.tightCornerRadius, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// Status lines are transient by design: they confirm what just happened and then
    /// get out of the way rather than accumulating.
    private func show(status message: String) {
        status = message
        Task {
            try? await Task.sleep(for: .seconds(4))
            if status == message { status = nil }
        }
    }
}

/// Pan-to-place picker for one of the saved places.
///
/// A fixed crosshair over a moving map beats a draggable pin: it works one-handed, and
/// the target stays under your thumb instead of under your finger.
struct SettingsPlaceLocationPicker: View {
    @Environment(\.dismiss) private var dismiss

    let kind: SavedPlaceKind
    let initialCoordinate: CLLocationCoordinate2D?
    let initialLabel: String
    let onSave: (CLLocationCoordinate2D, String) -> Void

    @State private var position: MapCameraPosition
    @State private var centre: CLLocationCoordinate2D
    @State private var hasCentre: Bool
    @State private var label: String

    init(
        kind: SavedPlaceKind,
        initialCoordinate: CLLocationCoordinate2D?,
        initialLabel: String,
        onSave: @escaping (CLLocationCoordinate2D, String) -> Void
    ) {
        self.kind = kind
        self.initialCoordinate = initialCoordinate
        self.initialLabel = initialLabel
        self.onSave = onSave

        if let initialCoordinate {
            _position = State(initialValue: .region(MKCoordinateRegion(
                center: initialCoordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
            )))
            _centre = State(initialValue: initialCoordinate)
            _hasCentre = State(initialValue: true)
        } else {
            _position = State(initialValue: .userLocation(fallback: .automatic))
            _centre = State(initialValue: CLLocationCoordinate2D(latitude: 0, longitude: 0))
            _hasCentre = State(initialValue: false)
        }
        _label = State(initialValue: initialLabel)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Map(position: $position) {
                    UserAnnotation()
                }
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                }
                .onMapCameraChange(frequency: .continuous) { context in
                    centre = context.region.center
                    hasCentre = true
                }
                .ignoresSafeArea(edges: .bottom)
                .accessibilityLabel("Map. Pan to place your \(kind.sheetLabel) location.")

                crosshair
                    .allowsHitTesting(false)

                controls
            }
            .navigationTitle("\(kind.title) location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var crosshair: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 38))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Theme.accent)
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent)
                .offset(y: -4)
            Spacer()
        }
        .padding(.bottom, 120)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Drag the map to put the pin where you start from.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)

            TextField("Label, e.g. \(kind.title)", text: $label)
                .textInputAutocapitalization(.words)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.tightCornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.tightCornerRadius, style: .continuous)
                        .strokeBorder(Theme.separator, lineWidth: 0.5)
                )

            HStack {
                Text(String(format: "%.4f, %.4f", centre.latitude, centre.longitude))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Set \(kind.sheetLabel)") {
                    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(centre, trimmed.isEmpty ? kind.title : trimmed)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(!hasCentre)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
        )
        .padding(16)
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }
}

/// Typed confirmation for the one action in the app that can't be undone.
///
/// A sheet rather than an alert, because an alert can't gate its destructive button on
/// what was typed, and gating is the entire point.
struct SettingsDeleteConfirmation: View {
    @Environment(\.dismiss) private var dismiss

    let visitCount: Int
    let onConfirm: () -> Void

    private static let phrase = "DELETE"

    @State private var typed = ""
    @FocusState private var isFocused: Bool

    private var isConfirmed: Bool {
        typed.trimmingCharacters(in: .whitespaces).uppercased() == Self.phrase
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.sectionSpacing) {
                    Card {
                        VStack(alignment: .leading, spacing: 14) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(.red)

                            Text("Delete \(visitCount) \(visitCount == 1 ? "visit" : "visits")?")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)

                            Text("Every visit, along with its notes, ratings and attached photos and video, will be removed from this device and from iCloud if sync is on. The parks themselves stay, but they'll all count as unvisited again. This can't be undone.")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Text("Export a backup first if you might want this back.")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(Theme.sunset)
                        }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Type \(Self.phrase) to confirm")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.textPrimary)

                            TextField(Self.phrase, text: $typed)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .focused($isFocused)
                                .font(.system(.body, design: .rounded).weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.tightCornerRadius, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: Theme.tightCornerRadius, style: .continuous)
                                        .strokeBorder(isConfirmed ? .red : Theme.separator, lineWidth: isConfirmed ? 1.5 : 0.5)
                                )
                                .animation(.smooth(duration: 0.2), value: isConfirmed)
                                .accessibilityLabel("Confirmation phrase")

                            Button(role: .destructive) {
                                onConfirm()
                                dismiss()
                            } label: {
                                Text("Delete all visits")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .disabled(!isConfirmed)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .background(Theme.background)
            .navigationTitle("Confirm deletion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { isFocused = true }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    SettingsScreen()
        .environment(LocationProvider())
        .environment(AppSettings())
        .environment(ServiceHub())
        .modelContainer(PersistenceController.makeInMemoryContainer())
}
