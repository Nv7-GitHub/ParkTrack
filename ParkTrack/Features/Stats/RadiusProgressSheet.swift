import SwiftUI
import CoreLocation

/// A ring's two halves: what you've been to and what's left inside it.
///
/// The ring itself only shows a percentage, and the obvious follow-up questions are "which
/// ones have I done" and "which ones haven't I" — a list of only the remaining answers half
/// of that.
struct RadiusProgressSheet: View {
    let completion: RadiusCompletion
    var origin: CLLocation?
    var anchorLabel: String = "you"

    @Environment(\.dismiss) private var dismiss
    @State private var showsVisited = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                    Card {
                        HStack(spacing: 14) {
                            ProgressRing(fraction: completion.fraction, lineWidth: 9)
                                .frame(width: 76, height: 76)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(completion.visited) of \(completion.total) visited")
                                    .font(.headline)
                                    .foregroundStyle(Theme.textPrimary)
                                Text(completion.total == 0
                                     ? "No parks found within \(Format.miles(completion.radiusMiles)) of \(anchorLabel) yet."
                                     : "\(Format.parkCount(completion.remaining.count)) still to go within \(Format.miles(completion.radiusMiles)) of \(anchorLabel).")
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Still to go · \(completion.remaining.count)")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        if completion.remaining.isEmpty {
                            Text(completion.total == 0
                                 ? "Nothing has been found in this ring yet."
                                 : "You've been to every park in this ring.")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                        } else {
                            VStack(spacing: 8) {
                                ForEach(completion.remaining, id: \.identifier) { park in
                                    RadiusParkRow(park: park, origin: origin, isVisited: false)
                                }
                            }
                        }
                    }

                    DisclosureGroup(isExpanded: $showsVisited) {
                        VStack(spacing: 8) {
                            ForEach(completion.visitedParks, id: \.identifier) { park in
                                RadiusParkRow(park: park, origin: origin, isVisited: true)
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("Been to · \(completion.visited)")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .disabled(completion.visited == 0)
                    .tint(Theme.accent)
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Within \(Format.miles(completion.radiusMiles))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct RadiusParkRow: View {
    let park: Park
    var origin: CLLocation?
    let isVisited: Bool

    var body: some View {
        NavigationLink {
            ParkDetailView(park: park)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isVisited ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isVisited ? Theme.accent : Theme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(park.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let origin {
                            Text(Format.distance(park.distance(from: origin)))
                        }
                        if let region = park.regionLabel {
                            Text(region).lineLimit(1)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.tightCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
