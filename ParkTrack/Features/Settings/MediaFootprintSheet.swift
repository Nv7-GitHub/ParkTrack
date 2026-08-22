import SwiftUI
import SwiftData

/// What the photos-and-video figure is actually made of.
///
/// The number on the Data card is a single figure for everything media takes up, which is
/// not enough to answer the question people actually have: how much of this is mine, and how
/// much is the app keeping on my behalf.
///
/// Deliberately says nothing about files. An earlier version of this printed the file count
/// against what the app could account for, which is a debugging instrument and not a thing
/// to show anybody: it is internal bookkeeping, it is alarming, and it is the developer's
/// problem to fix rather than the reader's to interpret.
struct MediaFootprintSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var footprint = DataExport.MediaFootprint()
    @State private var hasMeasured = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    total
                    rows
                    explanation
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Photos & video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            guard !hasMeasured else { return }
            hasMeasured = true
            footprint = DataExport.mediaFootprint(context: modelContext)
        }
    }

    private var total: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text(DataExport.preciseBytes(footprint.totalBytes))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("stored on this device")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var rows: some View {
        Card {
            VStack(spacing: 12) {
                row(
                    title: "Your photos and video",
                    detail: "Attached to visits you logged. This is what a backup carries.",
                    value: "\(footprint.ownItemCount)",
                    systemImage: "photo.stack",
                    tint: Theme.fern
                )
                Divider().overlay(Theme.separator)
                row(
                    title: "Friends' shared visits",
                    detail: "Mirrored from their feeds, each able to carry one attachment. Never included in a backup, and re-pulled rather than restored.",
                    value: "\(footprint.friendVisitCount)",
                    systemImage: "person.2.fill",
                    tint: Theme.sky
                )
                Divider().overlay(Theme.separator)
                row(
                    title: "Largest single file",
                    detail: "A video, usually.",
                    value: DataExport.preciseBytes(footprint.largestBytes),
                    systemImage: "arrow.up.right.square",
                    tint: Theme.bark
                )
            }
        }
    }

    private func row(
        title: String,
        detail: String,
        value: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(value)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Why this can read higher than a backup")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Friends' shared visits are kept here but never put in a backup — they come back from iCloud instead. And files occupy whole blocks on disk, so the total reads a little above the photos themselves.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }
}
