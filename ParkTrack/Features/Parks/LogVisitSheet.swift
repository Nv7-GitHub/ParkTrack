import AVFoundation
import CoreTransferable
import PhotosUI
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Logs a new visit, or edits an existing one.
///
/// Media is deliberately staged in memory as compressed bytes before anything is written:
/// the picker can hand back a 4K video, and inserting that into SwiftData before the user
/// commits would bloat the store for a visit they might cancel. `onSave` exists so callers
/// that keep their own derived state (the map, the home screen) can refresh without having
/// to observe the context.
struct LogVisitSheet: View {
    let park: Park
    let editingVisit: Visit?
    let onSave: () -> Void

    init(park: Park, onSave: @escaping () -> Void = {}) {
        self.init(park: park, editing: nil, onSave: onSave)
    }

    init(park: Park, editing visit: Visit?, onSave: @escaping () -> Void = {}) {
        self.park = park
        self.editingVisit = visit
        self.onSave = onSave
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var date = Date()
    @State private var includeDuration = false
    @State private var durationMinutes = 60
    @State private var rating = 0
    @State private var notes = ""
    @State private var companions = ""
    @State private var weather = ""

    @State private var pickerSelection: [PhotosPickerItem] = []
    @State private var attachments: [PendingMedia] = []
    @State private var existingMedia: [MediaItem] = []
    @State private var mediaToDelete: [MediaItem] = []

    @State private var processingCount = 0
    @State private var processingFailed = 0
    @State private var didLoad = false

    private var isProcessing: Bool { processingCount > 0 }
    private var isEditing: Bool { editingVisit != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date", selection: $date, displayedComponents: [.date, .hourAndMinute])

                    Toggle("Track how long", isOn: $includeDuration.animation(.smooth))
                    if includeDuration {
                        Stepper(value: $durationMinutes, in: 5...720, step: 5) {
                            HStack {
                                Text("Duration")
                                Spacer()
                                Text(Format.duration(minutes: durationMinutes))
                                    .foregroundStyle(Theme.textSecondary)
                                    .monospacedDigit()
                            }
                        }
                        .accessibilityValue(Format.duration(minutes: durationMinutes))
                    }
                } header: {
                    Text("When")
                } footer: {
                    Text("Backdating is fine — pick any past date to fill in a visit you never logged.")
                }

                Section("How was it") {
                    VisitRatingPicker(rating: $rating)
                        .padding(.vertical, 4)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                    TextField("Who came along", text: $companions)
                        .textInputAutocapitalization(.words)
                    TextField("Weather", text: $weather)
                        .textInputAutocapitalization(.sentences)
                }

                Section {
                    mediaStrip

                    PhotosPicker(
                        selection: $pickerSelection,
                        maxSelectionCount: 10,
                        selectionBehavior: .ordered,
                        matching: .any(of: [.images, .videos])
                    ) {
                        Label("Add photos or video", systemImage: "photo.badge.plus")
                    }
                    .tint(Theme.accent)

                    if isProcessing {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(processingCount == 1 ? "Compressing 1 item…" : "Compressing \(processingCount) items…")
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if processingFailed > 0 {
                        Label(
                            processingFailed == 1 ? "1 item couldn't be added." : "\(processingFailed) items couldn't be added.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(Theme.sunset)
                    }
                } header: {
                    Text("Memories")
                } footer: {
                    Text("Photos are downscaled and videos trimmed to 20 seconds so your library stays small.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(isEditing ? "Edit Visit" : "Log Visit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(isEditing ? "Edit Visit" : "Log Visit")
                            .font(.headline)
                        Text(park.name)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: save)
                        .fontWeight(.semibold)
                        .disabled(isProcessing)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onChange(of: pickerSelection) { _, selection in
            guard !selection.isEmpty else { return }
            pickerSelection = []
            Task { await ingest(selection) }
        }
        .task { load() }
    }

    // MARK: Media strip

    @ViewBuilder
    private var mediaStrip: some View {
        let total = existingMedia.count + attachments.count
        if total > 0 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(existingMedia, id: \.identifier) { item in
                        removable(label: item.isVideo ? "video" : "photo") {
                            MediaThumbnail(item: item, size: 84)
                        } remove: {
                            withAnimation(.smooth) {
                                existingMedia.removeAll { $0.identifier == item.identifier }
                                mediaToDelete.append(item)
                            }
                        }
                    }
                    ForEach(attachments) { pending in
                        removable(label: pending.isVideo ? "video" : "photo") {
                            PendingMediaThumbnail(pending: pending)
                        } remove: {
                            withAnimation(.smooth) {
                                attachments.removeAll { $0.id == pending.id }
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
        }
    }

    @ViewBuilder
    private func removable<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content,
        remove: @escaping () -> Void
    ) -> some View {
        content()
            .overlay(alignment: .topTrailing) {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(4)
                .accessibilityLabel("Remove \(label)")
            }
    }

    // MARK: Loading + saving

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        guard let visit = editingVisit else { return }
        date = visit.date
        if let minutes = visit.durationMinutes {
            includeDuration = true
            durationMinutes = minutes
        }
        rating = visit.rating
        notes = visit.notes
        companions = visit.companions
        weather = visit.weatherSummary ?? ""
        existingMedia = visit.sortedMedia
    }

    private func save() {
        let visit: Visit
        if let editingVisit {
            visit = editingVisit
        } else {
            visit = Visit(date: date)
            modelContext.insert(visit)
            visit.park = park
        }

        visit.date = date
        visit.durationMinutes = includeDuration ? durationMinutes : nil
        visit.rating = rating
        visit.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        visit.companions = companions.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWeather = weather.trimmingCharacters(in: .whitespacesAndNewlines)
        visit.weatherSummary = trimmedWeather.isEmpty ? nil : trimmedWeather

        for item in mediaToDelete {
            modelContext.delete(item)
        }
        for pending in attachments {
            let item = MediaItem(data: pending.data, isVideo: pending.isVideo, thumbnailData: pending.thumbnailData)
            modelContext.insert(item)
            item.visit = visit
        }

        try? modelContext.save()
        onSave()
        dismiss()
    }

    // MARK: Ingestion

    private func ingest(_ selection: [PhotosPickerItem]) async {
        processingCount += selection.count
        defer { processingCount = max(0, processingCount - selection.count) }

        for item in selection {
            if let pending = await Self.makePending(from: item) {
                withAnimation(.smooth) { attachments.append(pending) }
            } else {
                processingFailed += 1
            }
        }
    }

    private static func makePending(from item: PhotosPickerItem) async -> PendingMedia? {
        let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }

        if isVideo {
            guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else { return nil }
            defer { try? FileManager.default.removeItem(at: movie.url) }
            guard let compressed = await MediaCapture.compressVideo(at: movie.url) else { return nil }
            let thumbnail = await MediaCapture.videoThumbnail(from: compressed)
            return PendingMedia(data: compressed, isVideo: true, thumbnailData: thumbnail)
        }

        guard let raw = try? await item.loadTransferable(type: Data.self) else { return nil }
        let compressed = await Task.detached(priority: .userInitiated) {
            MediaCapture.compressImage(raw)
        }.value
        guard let compressed else { return nil }
        return PendingMedia(data: compressed, isVideo: false, thumbnailData: nil)
    }
}

/// Compressed bytes waiting to become a `MediaItem` once the user actually saves.
private struct PendingMedia: Identifiable {
    let id = UUID()
    let data: Data
    let isVideo: Bool
    let thumbnailData: Data?
}

private struct PendingMediaThumbnail: View {
    let pending: PendingMedia
    var size: CGFloat = 84

    private var image: UIImage? {
        UIImage(data: pending.isVideo ? (pending.thumbnailData ?? pending.data) : pending.data)
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Theme.separator
                Image(systemName: pending.isVideo ? "video.fill" : "photo")
                    .font(.system(size: size * 0.28, weight: .light))
                    .foregroundStyle(Theme.textSecondary)
            }
            if pending.isVideo {
                Image(systemName: "play.fill")
                    .font(.system(size: size * 0.22, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(size * 0.14)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Theme.tightCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.tightCornerRadius, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 0.5)
        )
        .accessibilityLabel(pending.isVideo ? "Attached video" : "Attached photo")
    }
}

/// The picker hands videos over as files, so we need a `Transferable` that copies the
/// received file somewhere we control before the system reclaims it.
private struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedMovie(url: destination)
        }
    }
}

/// Five-star input. Tappable and draggable, with an explicit "no rating" reset so a
/// mis-tap isn't permanent.
struct VisitRatingPicker: View {
    @Binding var rating: Int

    var body: some View {
        HStack(spacing: 10) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    withAnimation(.smooth(duration: 0.25)) {
                        rating = (rating == star) ? 0 : star
                    }
                } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(star <= rating ? Theme.sunset : Theme.separator)
                        .scaleEffect(star <= rating ? 1.0 : 0.92)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
                .accessibilityAddTraits(star <= rating ? [.isSelected] : [])
            }
            Spacer(minLength: 8)
            Text(rating == 0 ? "Not rated" : "\(rating)/5")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rating")
    }
}
