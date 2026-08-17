import SwiftUI
import SwiftData
import CoreLocation

/// The Friends tab: a leaderboard, a feed of what everyone has been logging, and the
/// publishing of your own numbers.
///
/// Everything renders from the local SwiftData mirror rather than from the network,
/// so the tab is instant and works offline — syncing only ever refreshes that mirror.
/// Publishing happens on appear and on pull-to-refresh rather than on every save,
/// which keeps the network off the visit-logging path where it would be felt.
struct FriendsScreen: View {
    private enum Pane: String, CaseIterable, Identifiable {
        case leaderboard
        case feed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .leaderboard: "Leaderboard"
            case .feed: "Feed"
            }
        }
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(LocationProvider.self) private var location
    @Environment(AppSettings.self) private var settings
    @Environment(ServiceHub.self) private var services

    @Query(sort: \Friend.addedAt) private var friends: [Friend]
    @Query private var parks: [Park]
    @State private var recordsCache = DerivedCache<Records>()
    @State private var streaksCache = DerivedCache<Streaks>()

    @State private var pane: Pane = .leaderboard
    @State private var metric: LeaderboardMetric = .parks
    @State private var isAddingFriend = false
    @State private var hasPublished = false

    private var social: SocialService? { services.social }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.sectionSpacing) {
                    if social?.backendKind == .mock {
                        FriendsSampleDataBanner()
                    }

                    if trimmedDisplayName.isEmpty {
                        FriendsDisplayNameCard(settings: settings)
                    }

                    Picker("Section", selection: $pane) {
                        ForEach(Pane.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Friends section")

                    switch pane {
                    case .leaderboard:
                        FriendsLeaderboardView(
                            entries: entries,
                            metric: $metric,
                            onAddFriend: { isAddingFriend = true }
                        )
                    case .feed:
                        FriendsFeedView(
                            friends: friends,
                            onAddFriend: { isAddingFriend = true }
                        )
                    }

                    if let error = social?.lastError, !error.isEmpty {
                        FriendsErrorNote(message: error)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .animation(.smooth(duration: 0.3), value: pane)
            }
            .tabBarBottomInset()
            .background(Theme.background)
            .refreshable { await syncEverything() }
            .navigationTitle("Friends")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isAddingFriend = true
                    } label: {
                        Image(systemName: "person.badge.plus")
                    }
                    .disabled(social == nil)
                    .accessibilityLabel("Add friend")
                }
            }
            .navigationDestination(for: Friend.self) { friend in
                FriendDetailScreen(friend: friend, social: social)
            }
            .sheet(isPresented: $isAddingFriend) {
                if let social {
                    AddFriendSheet(social: social, myCode: settings.friendCode)
                }
            }
            .task(id: social == nil) { await start() }
        }
    }

    // MARK: - Leaderboard data

    private var entries: [LeaderboardEntry] {
        [myEntry] + friends.map(LeaderboardEntry.init(friend:))
    }

    /// The user's own row, computed from the same engine the Stats tab uses so the two
    /// screens can never disagree about how many parks you've been to.
    private var myEntry: LeaderboardEntry {
        let signature = StatsSignature(
            parkCount: parks.count,
            visitCount: modelContext.visitCount(),
            anchor: originLocation?.coordinate
        )
        let records = recordsCache.value(for: signature) {
            StatsEngine.records(parks: parks, origin: originLocation)
        }
        let streaks = streaksCache.value(for: signature) {
            StatsEngine.streaks(parks: parks)
        }
        return LeaderboardEntry(
            id: settings.friendCode,
            name: trimmedDisplayName.isEmpty ? "You" : trimmedDisplayName,
            isMe: true,
            friend: nil,
            totalParks: records.totalParks,
            parksThisMonth: records.parksThisMonth,
            citiesCount: records.distinctCities,
            streakWeeks: streaks.currentWeeks
        )
    }

    private var trimmedDisplayName: String {
        settings.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var originLocation: CLLocation? {
        if let current = location.currentLocation { return current }
        return settings.homeCoordinate.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
    }

    // MARK: - Syncing

    private func start() async {
        guard let social else { return }
        await social.refreshAll()
        guard !hasPublished else { return }
        hasPublished = true
        await publish(using: social)
    }

    private func syncEverything() async {
        guard let social else { return }
        await social.refreshAll()
        await publish(using: social)
    }

    /// Nothing goes out until the user has named themselves — a friend list full of
    /// six-character codes helps nobody.
    private func publish(using social: SocialService) async {
        let name = trimmedDisplayName
        guard !name.isEmpty else { return }

        let records = StatsEngine.records(parks: parks, origin: originLocation)
        let streaks = StatsEngine.streaks(parks: parks)
        let profile = FriendProfilePayload(
            code: settings.friendCode,
            displayName: name,
            totalParks: records.totalParks,
            totalVisits: records.totalVisits,
            citiesCount: records.distinctCities,
            currentStreakWeeks: streaks.currentWeeks,
            parksThisMonth: records.parksThisMonth
        )
        await social.publishMyData(parks: parks, profile: profile)
    }
}

/// Says plainly that the friends on screen aren't real people.
///
/// The mock backend exists so the tab is explorable without CloudKit; letting it pass
/// for the real thing would be a lie the user can't check.
private struct FriendsSampleDataBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .font(.subheadline)
                .foregroundStyle(Theme.sky)
            VStack(alignment: .leading, spacing: 2) {
                Text("Friend sync isn't configured in this build")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("The people and visits below are sample data. Nothing you publish leaves this device.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.sky.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.tightCornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Asks for a display name, which publishing is gated on.
/// The card is only on screen while no name has been saved, so the field edits a local
/// draft and writes back on submit or when it loses focus. Binding straight to
/// `settings.displayName` meant the first keystroke satisfied the "no name yet" condition
/// that put this card on screen, and it vanished mid-word taking the keyboard with it.
private struct FriendsDisplayNameCard: View {
    @Bindable var settings: AppSettings

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        settings.displayName = trimmed
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Pick a name", subtitle: "Friends see this next to your numbers")
                TextField("Your name", text: $draft)
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit(commit)
                    .onChange(of: isFocused) { _, focused in
                        if !focused { commit() }
                    }
                    .onAppear { draft = settings.displayName }
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .font(.body)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.tightCornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.tightCornerRadius, style: .continuous)
                            .strokeBorder(Theme.separator, lineWidth: 1)
                    )
                    .accessibilityLabel("Your display name")
                Text("Your stats stay unpublished until you set one. Tap Done to save it.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

/// Whatever the sync last failed at, in the words the service gave us.
private struct FriendsErrorNote: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Theme.sunset)
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.sunset.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.tightCornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
