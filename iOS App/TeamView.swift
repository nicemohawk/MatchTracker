// TeamView.swift
// MatchTracker
//
// The Team tab, reimagined as a Strava-club leaderboard rather than a settings form: a metric
// picker re-ranks teammates with a spring, the podium gets medal treatment, and each row expands
// inline to the full stat set. Setup (join / switch teams / features) lives in supporting cards
// so the leaderboard is the focus. See TeamRosterViews.swift and TeamJoinCard.swift.

import SwiftUI
import MatchTrackerKit

struct TeamView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var uploads: UploadService
    @EnvironmentObject private var matches: MatchStore

    @Environment(EntitlementStore.self) private var entitlements

    @State private var teamCode = ""
    @State private var playerName = ""
    @State private var loadState: LoadState = .idle
    @State private var newTeamCode = ""
    @State private var showingPaywall = false
    @State private var selectedMetric: TeamMetric = .workrate
    @State private var expandedPlayer: String?

    enum LoadState {
        case idle, loading, loaded(TeamStats), failed(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    if settings.teamCode.isEmpty {
                        JoinTeamCard(playerName: $playerName, teamCode: $teamCode, onJoin: commitAndLoad)
                    } else {
                        TeamHeaderBar(
                            teamCode: settings.teamCode,
                            memberCount: loadedMemberCount,
                            isLoading: isLoading,
                            onRefresh: { Task { await load() } }
                        )
                        leaderboardSection
                        MembershipsCard(
                            newTeamCode: $newTeamCode,
                            onShowPaywall: { showingPaywall = true },
                            onSelect: selectTeam
                        )
                        TeamFeaturesCard(teamCode: settings.teamCode, onShowPaywall: { showingPaywall = true })
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }
            .background(Theme.background.ignoresSafeArea())
            .scrollContentBackground(.hidden)
            .navigationTitle("Team")
            .refreshable { await load() }
            .onAppear {
                teamCode = settings.teamCode
                playerName = settings.playerName
                if !teamCode.isEmpty, case .idle = loadState { Task { await load() } }
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView(entitlements: entitlements)
            }
        }
    }

    // MARK: - Leaderboard

    @ViewBuilder
    private var leaderboardSection: some View {
        switch loadState {
        case .idle, .loading:
            SkeletonLeaderboard()
        case .loaded(let stats) where stats.players.isEmpty:
            emptyRosterCard
        case .loaded(let stats):
            MetricPicker(selection: $selectedMetric) { metric in
                withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                    selectedMetric = metric
                }
            }
            let ranked = rankedPlayers(stats.players)
            LazyVStack(spacing: 10) {
                ForEach(Array(ranked.enumerated()), id: \.element.name) { index, player in
                    LeaderboardRow(
                        player: player,
                        rank: index + 1,
                        metric: selectedMetric,
                        isYou: isYou(player.name),
                        isExpanded: expandedPlayer == player.name,
                        onTap: { toggleExpanded(player.name) }
                    )
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.82), value: selectedMetric)
        case .failed(let message):
            failureCard(message)
        }
    }

    /// Sort by the selected metric (descending), tie-broken by name so ordering stays stable.
    private func rankedPlayers(_ players: [TeamStats.Player]) -> [TeamStats.Player] {
        players.sorted { lhs, rhs in
            let left = selectedMetric.value(lhs)
            let right = selectedMetric.value(rhs)
            if left == right { return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending }
            return left > right
        }
    }

    private func toggleExpanded(_ name: String) {
        Haptics.selection()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            expandedPlayer = expandedPlayer == name ? nil : name
        }
    }

    private func isYou(_ name: String) -> Bool {
        let mine = settings.playerName.trimmingCharacters(in: .whitespaces)
        guard !mine.isEmpty else { return false }
        return name.localizedCaseInsensitiveCompare(mine) == .orderedSame
    }

    // MARK: - State cards

    private var emptyRosterCard: some View {
        VStack {
            ContentUnavailableView(
                "No Teammates Yet",
                systemImage: "person.crop.circle.badge.questionmark",
                description: Text("Stats appear once teammates upload matches.")
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .themedCard()
    }

    private func failureCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text("Couldn't reach the team")
                    .font(.system(.headline, design: .rounded))
            } icon: {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(Theme.sprint)
            }
            Text(message).font(.caption).foregroundStyle(.secondary)
            localFallback
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .themedCard()
    }

    /// Local-only aggregates from this device's matches when the backend is unavailable.
    private var localFallback: some View {
        let count = matches.matches.count
        let distance = matches.matches.reduce(0.0) { $0 + $1.distanceMeters }
        let goals = matches.matches.reduce(0) { total, summary in
            total + (summary.record?.events.filter { $0.kind == .goalMine }.count ?? 0)
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Your local totals").captionLabel()
            HStack(spacing: 18) {
                fallbackStat("\(count)", "matches")
                fallbackStat(MatchFormat.distance(distance), "distance")
                fallbackStat("\(goals)", "goals")
            }
        }
        .padding(.top, 4)
    }

    private func fallbackStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(label).captionLabel()
        }
    }

    // MARK: - Derived state

    private var loadedMemberCount: Int? {
        if case .loaded(let stats) = loadState { return stats.players.count }
        return nil
    }

    private var isLoading: Bool {
        if case .loading = loadState { return true }
        return false
    }

    // MARK: - Actions

    /// Star a different membership as the upload/watch default and reload its roster.
    private func selectTeam(_ code: String) {
        settings.teamCode = code
        teamCode = code
        environment.settingsChanged()
        expandedPlayer = nil
        Task { await load() }
    }

    private func commitAndLoad() {
        settings.playerName = playerName
        let code = teamCode.uppercased()
        settings.teamCode = code
        teamCode = code
        // Mirror the joined code into memberships so it appears in My Teams for switching/removal.
        if !settings.teamMemberships.contains(where: { $0.code == code }) {
            settings.teamMemberships.append(TeamMembership(code: code, name: nil, displayInitialsOnly: false))
        }
        environment.settingsChanged()
        Task { await load() }
    }

    private func load() async {
        guard !teamCode.isEmpty else { loadState = .idle; return }
        loadState = .loading
        do {
            let stats = try await uploads.fetchTeamStats(code: teamCode)
            loadState = .loaded(stats)
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }
}
