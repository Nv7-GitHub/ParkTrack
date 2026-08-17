import SwiftData
import SwiftUI

/// Repairs a history where "mark visited" used to mean "visited today".
///
/// Until visits could be undated, marking a park you'd been to years ago wrote a visit
/// dated the moment you tapped it. A backlog cleared in one sitting therefore landed on a
/// single day of every timeline, streak and heatmap in the app. This is where that gets
/// undone: pick the entries that were never really about a particular day and drop their
/// dates, keeping the parks visited and the counts intact.
///
/// It works in both directions, because the guess is not always right — a visit that
/// genuinely happened on the day it was logged can be left alone or, if it has already been
/// cleared, given its date back.
struct FixMarkedVisitsSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Visit.date, order: .reverse) private var visits: [Visit]

    @State private var mode: Mode = .dated
    @State private var selection: Set<UUID> = []
    @State private var didSeedSelection = false
    @State private var status: String?

    private enum Mode: String, CaseIterable, Identifiable {
        case dated, undated
        var id: String { rawValue }

        var title: String {
            switch self {
            case .dated: return "Has a date"
            case .undated: return "No date"
            }
        }
    }

    /// Only entries with nothing but the fact of the visit are offered.
    ///
    /// A visit carrying a rating, a note, a duration, companions or a photo was written by
    /// someone sitting down to describe a day out — whatever its date says, it is not one of
    /// the marks this screen exists to clean up, so it is never listed and can never be
    /// altered here by a stray "select all".
    private var candidates: [Visit] {
        visits.filter { $0.park != nil && $0.hasNoDetails && $0.isUndated == (mode == .undated) }
    }

    private var isSelectAll: Bool {
        !candidates.isEmpty && selection.count < candidates.count
    }

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    emptyState
                } else {
                    List {
                        Section {
                            ForEach(candidates, id: \.identifier) { visit in
                                row(for: visit)
                            }
                        } header: {
                            Text(mode == .dated
                                 ? "Dated visits with no other detail"
                                 : "Visits with no date")
                                .textCase(nil)
                        } footer: {
                            Text(mode == .dated
                                 ? "Visits you rated, described, timed or photographed are never listed here — those are real logs, whatever their date."
                                 : "Restoring a date puts the visit back on your timeline, streak and heatmap, dated as it is now.")
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .background(Theme.background)
                }
            }
            .navigationTitle("Fix marked visits")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .safeAreaInset(edge: .bottom) { actionBar }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSelectAll ? "Select All" : "Select None") {
                        withAnimation(.smooth(duration: 0.2)) {
                            selection = isSelectAll ? Set(candidates.map(\.identifier)) : []
                        }
                    }
                    .disabled(candidates.isEmpty)
                }
            }
            .onAppear(perform: seedSelection)
            .onChange(of: mode) { _, _ in
                // Everything is selected by default: the whole point is that most of these
                // were never real logs, so deselecting the handful that were is less work
                // than ticking ninety-seven boxes.
                selection = Set(candidates.map(\.identifier))
            }
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            Picker("Which visits", selection: $mode) {
                ForEach(Mode.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
        }
        .background(.bar)
    }

    @ViewBuilder
    private var actionBar: some View {
        if !candidates.isEmpty {
            VStack(spacing: 8) {
                if let status {
                    Text(status)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.moss)
                        .transition(.opacity)
                }
                Button(action: apply) {
                    Text(actionTitle)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(selection.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .background(.bar)
            .animation(.smooth(duration: 0.25), value: status)
        }
    }

    private var actionTitle: String {
        let count = selection.count
        guard count > 0 else {
            return mode == .dated ? "Remove dates" : "Restore dates"
        }
        let noun = count == 1 ? "visit" : "visits"
        return mode == .dated
            ? "Remove the date from \(count) \(noun)"
            : "Restore the date on \(count) \(noun)"
    }

    private var emptyState: some View {
        EmptyStateView(
            systemImage: mode == .dated ? "checkmark.seal" : "calendar.badge.exclamationmark",
            title: mode == .dated ? "Nothing to clean up" : "No undated visits",
            message: mode == .dated
                ? "Every dated visit you've logged has details on it, so none of them look like a park you simply marked as visited."
                : "Nothing is currently marked visited without a date. Marking a park visited from its page, or in bulk on the map, adds one here."
        )
        .frame(maxHeight: .infinity)
        .background(Theme.background)
    }

    private func row(for visit: Visit) -> some View {
        let isSelected = selection.contains(visit.identifier)

        return Button {
            withAnimation(.smooth(duration: 0.15)) {
                if isSelected {
                    selection.remove(visit.identifier)
                } else {
                    selection.insert(visit.identifier)
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Theme.accent : Theme.separator)
                    .contentTransition(.symbolEffect(.replace))

                VStack(alignment: .leading, spacing: 2) {
                    Text(visit.park?.name ?? "Unknown park")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    Text(visit.isUndated
                         ? "No date · added \(Format.date(visit.createdAt))"
                         : Format.date(visit.date))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Everything ticked on first appearance, for the same reason the toolbar leads with
    /// "Select All": the common case is that nearly all of these were marks, not logs.
    private func seedSelection() {
        guard !didSeedSelection else { return }
        didSeedSelection = true
        selection = Set(candidates.map(\.identifier))
    }

    private func apply() {
        let makeUndated = mode == .dated
        let targets = candidates.filter { selection.contains($0.identifier) }
        guard !targets.isEmpty else { return }

        for visit in targets {
            visit.isUndated = makeUndated
            // A restored date has to be something. The row's creation time is the only
            // honest answer the store holds, and it is what the visit used to claim.
            if !makeUndated { visit.date = visit.createdAt }
        }
        try? modelContext.save()

        let noun = targets.count == 1 ? "visit" : "visits"
        status = makeUndated
            ? "\(targets.count) \(noun) no longer count towards your timeline."
            : "\(targets.count) \(noun) are back on your timeline."
        selection = []
    }
}
