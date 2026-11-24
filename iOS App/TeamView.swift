// TeamView.swift
// MatchTracker

import SwiftUI
import MatchTrackerKit

/// Where the Team tab can go.
enum TeamDestination: Hashable {
    case leaderboard, squad, formation, coach, comparison, fixtures
    case player(String)
}

/// The Team tab. A stack on iPhone; on iPad the tab itself is the split view, so every page,
/// including Coach, gets the detail column rather than a split view pushed inside a stack.
struct TeamView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    @State private var team = TeamModel()
    @State private var path: [TeamDestination] = []
    @State private var selection: TeamDestination? = .leaderboard
    @State private var sheet: TeamSheet?

    enum TeamSheet: String, Identifiable {
        case join, create, manage, plan
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if settings.teamCode.isEmpty {
                NavigationStack {
                    noTeam.navigationTitle("Team")
                }
            } else if horizontalSizeClass == .regular {
                splitView
            } else {
                NavigationStack(path: $path) {
                    home
                        .navigationDestination(for: TeamDestination.self, destination: destination)
                }
            }
        }
        .task(id: settings.teamCode) { await team.load(code: settings.teamCode) }
        .onChange(of: settings.teamCode) {
            path = []
            selection = .leaderboard
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await team.load(code: settings.teamCode) } }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .join: TeamJoinSheet()
            case .create: TeamCreateSheet()
            case .manage: TeamManageSheet(sharedName: team.season?.teamName)
            case .plan: PaywallView(entitlements: entitlements)
            }
        }
    }

    private var teamName: String { settings.teamName(sharedName: team.season?.teamName) }

    // MARK: No team

    private var noTeam: some View {
        ContentUnavailableView {
            Label("Play with your team", systemImage: "person.3")
        } description: {
            Text("See who covered the most ground this week, and set up a formation.")
        } actions: {
            VStack(spacing: 12) {
                Button { sheet = .join } label: {
                    Text("Join a Team").frame(minWidth: 200)
                }
                .buttonStyle(.prominentAction)
                Button { sheet = .create } label: {
                    Text("Create a Team").frame(minWidth: 200)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
    }

    // MARK: iPhone

    private var home: some View {
        List {
            TeamLeaderboardSections(team: team, showsSquadLink: true)
            Section {
                pageLinks { page in
                    NavigationLink(value: page.destination) {
                        Label(page.title, systemImage: page.systemImage)
                    }
                }
            }
            Section {
                inviteLink
            } footer: {
                refreshNote
            }
        }
        .navigationTitle(teamName)
        .toolbar { manageButton }
        .refreshable { await team.load(code: settings.teamCode) }
    }

    // MARK: iPad

    private var splitView: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("Leaderboard", systemImage: "list.number").tag(TeamDestination.leaderboard)
                    pageLinks { page in
                        Label(page.title, systemImage: page.systemImage).tag(page.destination)
                    }
                }
                if let players = team.season?.players, !players.isEmpty {
                    Section("Squad") {
                        ForEach(players.map(\.name).sorted(), id: \.self) { name in
                            TeamPlayerName(name: name).tag(TeamDestination.player(name))
                        }
                    }
                }
                Section { inviteLink }
            }
            .navigationTitle(teamName)
            .navigationBarTitleDisplayMode(.large)
            .toolbar { manageButton }
        } detail: {
            NavigationStack {
                destination(selection ?? .leaderboard)
            }
            .id(selection)
        }
        .navigationSplitViewStyle(.balanced)
    }

    // MARK: Shared pieces

    private struct Page {
        let destination: TeamDestination
        let title: String
        let systemImage: String
        var needsPlan = false
    }

    private static let pages = [
        Page(destination: .formation, title: "Formation", systemImage: "sportscourt", needsPlan: true),
        Page(destination: .coach, title: "Coach", systemImage: "clipboard", needsPlan: true),
        Page(destination: .fixtures, title: "Fixtures", systemImage: "calendar"),
        Page(destination: .comparison, title: "How you compare", systemImage: "chart.bar")
    ]

    private func pageLinks<Row: View>(@ViewBuilder row: @escaping (Page) -> Row) -> some View {
        ForEach(Self.pages, id: \.destination) { page in
            if page.needsPlan && !entitlements.entitledToTeam {
                lockedPage(page)
            } else {
                row(page)
            }
        }
    }

    private func lockedPage(_ page: Page) -> some View {
        Button { sheet = .plan } label: {
            LabeledContent {
                Text("Team plan")
            } label: {
                Label(page.title, systemImage: page.systemImage)
            }
        }
        .tint(.primary)
    }

    private var inviteLink: some View {
        ShareLink(item: TeamInvite(code: settings.teamCode, name: settings.teamName(orNil: team.season?.teamName)).message) {
            Label("Invite teammates", systemImage: "square.and.arrow.up")
        }
    }

    private var manageButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Manage team", systemImage: "person.2.badge.gearshape") { sheet = .manage }
        }
    }

    @ViewBuilder private var refreshNote: some View {
        if let problem = team.refreshProblem {
            Text("Couldn't refresh. \(problem) Showing what was here before.")
        }
    }

    @ViewBuilder
    private func destination(_ destination: TeamDestination) -> some View {
        switch destination {
        case .leaderboard:
            List {
                TeamLeaderboardSections(team: team, showsSquadLink: false)
                if team.refreshProblem != nil {
                    Section {} footer: { refreshNote }
                }
            }
            .readableFormWidth()
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Leaderboard")
            .refreshable { await team.load(code: settings.teamCode) }
        case .squad:
            TeamSquadView(team: team)
        case .formation:
            FormationView(teamCode: settings.teamCode)
        case .coach:
            CoachDashboardView(teamCode: settings.teamCode)
        case .comparison:
            CohortBenchmarkView()
        case .fixtures:
            FixturesListView()
        case .player(let name):
            TeamPlayerView(name: name, team: team)
        }
    }
}

// MARK: - Model

@Observable
@MainActor
final class TeamModel {
    enum Phase: Equatable { case loading, loaded, failed(String) }

    private(set) var phase: Phase = .loading
    private(set) var season: TeamStats?
    /// Nil when the server can't say what happened this week.
    private(set) var week: TeamStats?
    /// Set when a refresh failed but there's something older to show.
    private(set) var refreshProblem: String?
    @ObservationIgnored private var code = ""

    func load(code newCode: String) async {
        guard !newCode.isEmpty else { return }
        if newCode != code {
            code = newCode
            season = nil
            week = nil
            refreshProblem = nil
        }
        if season == nil { phase = .loading }
        do {
            async let seasonStats = TeamService.stats(code: newCode, since: Self.seasonStart)
            async let weekStats = TeamService.stats(code: newCode, since: Self.weekStart)
            let (newSeason, newWeek) = try await (seasonStats, weekStats)
            guard newCode == code else { return }
            season = newSeason
            week = Self.isOneWeek(newWeek) ? newWeek : nil
            refreshProblem = nil
            phase = .loaded
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            guard newCode == code else { return }
            if season == nil {
                phase = .failed(TeamService.explain(error))
            } else {
                refreshProblem = TeamService.explain(error)
            }
        }
    }

    static var weekStart: Date { Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date() }

    static var seasonStart: Date {
        let term = SeasonSummary.Term(containing: Date())
        return Calendar.current.date(from: DateComponents(year: term.year, month: term.isFall ? 7 : 1, day: 1)) ?? .distantPast
    }

    static var seasonTitle: String { SeasonSummary.Term(containing: Date()).title }

    /// A server that ignores `since` sends everything ever recorded; don't call that a week.
    private static func isOneWeek(_ stats: TeamStats) -> Bool {
        stats.players.allSatisfy { ($0.minutesPlayed ?? 0) < 14 * 60 && $0.matchesPlayed <= 10 }
    }
}

// MARK: - Settings

extension SettingsStore {
    /// The current team's name: what this player calls it, else what the server calls it.
    func teamName(orNil sharedName: String?) -> String? {
        let own = teamMemberships.first { $0.code == teamCode }?.name
        return [own, sharedName].compactMap { $0 }.first { !$0.isEmpty }
    }

    /// Never the code: a code isn't a name.
    func teamName(sharedName: String?) -> String { teamName(orNil: sharedName) ?? "Your team" }

    func isMe(_ name: String) -> Bool {
        let mine = playerName.trimmingCharacters(in: .whitespaces)
        return !mine.isEmpty && name.localizedCaseInsensitiveCompare(mine) == .orderedSame
    }

    /// Makes a team the current one, adding it if it's new.
    func enterTeam(code: String, name: String?) {
        var memberships = teamMemberships
        if let index = memberships.firstIndex(where: { $0.code == code }) {
            if let name { memberships[index].name = name }
        } else {
            memberships.append(TeamMembership(code: code, name: name))
        }
        teamMemberships = memberships
        teamCode = code
    }
}
