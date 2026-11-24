// TeamView.swift
// MatchTracker

import SwiftUI
import MatchTrackerKit

/// Where the Team tab can go.
enum TeamDestination: Hashable {
    case leaderboard, squad, formation, matches, whosIn, comparison, fixtures
    case player(String)
}

/// The Team tab: the same for everyone on the team. A stack on iPhone; on iPad the tab itself is the
/// split view, so every page gets the detail column rather than a split view pushed inside a stack.
struct TeamView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    @State private var team = TeamModel()
    @State private var path: [TeamDestination] = []
    @State private var selection: TeamDestination? = .leaderboard
    @State private var sheet: TeamSheet?

    enum TeamSheet: String, Identifiable {
        case join, create, manage
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if code.isEmpty {
                NavigationStack {
                    ViewThatFits(in: .vertical) {
                        noTeam
                        ScrollView { noTeam }
                    }
                    .navigationTitle("Team")
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
        .task(id: code) { await team.load(code: code) }
        .task(id: LiveWatch(code: code, isActive: scenePhase == .active)) {
            while scenePhase == .active, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if !Task.isCancelled { await team.refreshPlaying() }
            }
        }
        .onChange(of: code) {
            path = []
            selection = .leaderboard
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await team.load(code: code) } }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .join: TeamJoinSheet()
            case .create: TeamCreateSheet()
            case .manage: TeamManageSheet(sharedName: team.season?.teamName)
            }
        }
    }

    private struct LiveWatch: Equatable {
        let code: String
        let isActive: Bool
    }

    private var code: String { settings.viewedTeam }
    private var teamName: String { settings.teamName(code, sharedName: team.season?.teamName) ?? "Your team" }
    private var isCoach: Bool { settings.team(code)?.isCoach ?? false }

    // MARK: No team

    private var noTeam: some View {
        ContentUnavailableView {
            Label("Play with your team", systemImage: "person.3")
        } description: {
            Text("See who played and who covered the most ground. Free for everyone, with no account and no coach needed.")
        } actions: {
            VStack(spacing: 12) {
                Button { sheet = .create } label: {
                    Text("Start a Team").frame(minWidth: 200)
                }
                .buttonStyle(.prominentAction)
                Button { sheet = .join } label: {
                    Text("Join a Team").frame(minWidth: 200)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
    }

    // MARK: iPhone

    private var home: some View {
        List {
            teamSections(showsSquadLink: true)
            Section {
                ForEach(Self.pages, id: \.destination) { page in
                    NavigationLink(value: page.destination) { label(page) }
                }
            }
            inviteSection
        }
        .navigationTitle(teamName)
        .toolbar { toolbar }
        .refreshable { await team.load(code: code) }
    }

    // MARK: iPad

    private var splitView: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("Leaderboard", systemImage: "list.number").tag(TeamDestination.leaderboard)
                    ForEach(Self.pages, id: \.destination) { page in
                        label(page).tag(page.destination)
                    }
                }
                if let players = team.season?.players, !players.isEmpty {
                    Section("Squad") {
                        ForEach(players.map(\.name).sorted(), id: \.self) { name in
                            TeamPlayerName(name: name).tag(TeamDestination.player(name))
                        }
                    }
                }
                inviteSection
            }
            .navigationTitle(teamName)
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbar }
        } detail: {
            NavigationStack {
                destination(selection ?? .leaderboard)
                    .navigationDestination(for: TeamDestination.self, destination: destination)
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
    }

    private static let pages = [
        Page(destination: .matches, title: "Team matches", systemImage: "clock"),
        Page(destination: .formation, title: "Formation", systemImage: "sportscourt"),
        Page(destination: .whosIn, title: "Who's in", systemImage: "checklist"),
        Page(destination: .fixtures, title: "Fixtures", systemImage: "calendar"),
        Page(destination: .comparison, title: "How you compare", systemImage: "chart.bar")
    ]

    /// Who's playing, the leaderboard and the last match. A coach sees the minutes first.
    @ViewBuilder
    private func teamSections(showsSquadLink: Bool) -> some View {
        if let problem = team.refreshProblem {
            Section {
                Text("\(problem) This is from last time.").foregroundStyle(.secondary)
            }
        }
        if !team.playing.isEmpty {
            Section {
                NavigationLink(value: TeamDestination.matches) {
                    Label("\(TeamModel.listed(team.playing)) playing now", systemImage: "dot.radiowaves.left.and.right")
                }
            }
        }
        if isCoach { TeamLastMatchSection(match: team.lastMatch, isLeastFirst: true) }
        TeamLeaderboardSections(team: team, code: code, showsSquadLink: showsSquadLink)
        if !isCoach { TeamLastMatchSection(match: team.lastMatch, isLeastFirst: false) }
    }

    @ViewBuilder
    private func label(_ page: Page) -> some View {
        let label = Label(page.title, systemImage: page.systemImage)
        if page.destination == .fixtures, let next = FixtureStore.shared.next {
            label.badge(Text(next.relativeDay))
        } else {
            label
        }
    }

    /// Nobody can invite people to a team that has turned them away.
    @ViewBuilder private var inviteSection: some View {
        if case .turnedAway = team.phase {} else {
            Section {
                ShareLink(item: settings.invite(code, sharedName: team.season?.teamName).message) {
                    Label("Invite teammates", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if settings.teamMemberships.count > 1 {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Switch team", systemImage: "arrow.left.arrow.right") {
                    Picker("Team", selection: Binding(get: { code }, set: { settings.viewedTeam = $0 })) {
                        ForEach(settings.teamMemberships) { Text($0.name ?? $0.code).tag($0.code) }
                    }
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("Manage team", systemImage: "person.2.badge.gearshape") { sheet = .manage }
        }
    }

    @ViewBuilder
    private func destination(_ destination: TeamDestination) -> some View {
        switch destination {
        case .leaderboard:
            List {
                teamSections(showsSquadLink: false)
            }
            .readableFormWidth()
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Leaderboard")
            .refreshable { await team.load(code: code) }
        case .squad:
            TeamSquadView(team: team, code: code)
        case .formation:
            FormationView(teamCode: code)
        case .matches:
            TeamMatchesView(teamCode: code)
        case .whosIn:
            TeamWhosInView(teamCode: code, sharedName: team.season?.teamName)
        case .comparison:
            CohortBenchmarkView()
        case .fixtures:
            FixturesListView()
        case .player(let name):
            TeamPlayerView(name: name, team: team, code: code)
        }
    }
}

// MARK: - Model

@Observable
@MainActor
final class TeamModel {
    enum Phase: Equatable {
        case loading, loaded, failed(String)
        /// The server says this player isn't on the team.
        case turnedAway(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var season: TeamStats?
    /// Nil when the server can't say what happened this week.
    private(set) var week: TeamStats?
    /// The newest match anyone shared in the last few weeks, and who was in it.
    private(set) var lastMatch: TeamMatchMinutes?
    /// Teammates with a match going right now.
    private(set) var playing: [String] = []
    /// Set when a refresh failed but there's something older to show.
    private(set) var refreshProblem: String?
    @ObservationIgnored private var code = ""

    private static let lastMatchHours = 4 * 7 * 24

    func load(code newCode: String) async {
        guard !newCode.isEmpty else { return }
        if newCode != code {
            code = newCode
            let saved = TeamCache.load(newCode)
            season = saved?.season
            lastMatch = saved?.lastMatch
            week = nil
            playing = []
            refreshProblem = nil
            phase = season == nil ? .loading : .loaded
        }
        if season == nil { phase = .loading }
        await TeamService.tellServerAboutTeams()
        do {
            async let seasonStats = TeamService.stats(code: newCode, since: Self.seasonStart)
            async let weekStats = TeamService.stats(code: newCode, since: Self.weekStart)
            let (newSeason, newWeek) = try await (seasonStats, weekStats)
            guard newCode == code else { return }
            season = newSeason
            week = Self.isOneWeek(newWeek) ? newWeek : nil
            refreshProblem = nil
            phase = .loaded
            // Worth having, not worth failing for.
            if let events = try? await TeamService.events(code: newCode, sinceHours: Self.lastMatchHours), newCode == code {
                lastMatch = TeamMinutes.matches(from: events).first
            }
            guard newCode == code else { return }
            TeamCache(season: newSeason, lastMatch: lastMatch).save(newCode)
            await refreshPlaying()
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            guard newCode == code else { return }
            if TeamService.isTurnedAway(error) {
                TeamCache.remove(newCode)
                season = nil
                week = nil
                lastMatch = nil
                playing = []
                phase = .turnedAway(TeamService.explain(error))
            } else if season == nil {
                phase = .failed(TeamService.explain(error))
            } else {
                refreshProblem = TeamService.explain(error)
            }
        }
    }

    func refreshPlaying() async {
        let asked = code
        guard phase == .loaded, let players = try? await TeamService.livePlayers(code: asked), asked == code else { return }
        playing = players.filter { !$0.stale }.map(\.playerName).sorted()
    }

    /// "Maya is", "Maya and Sam are", "Maya, Sam and 3 others are".
    static func listed(_ names: [String]) -> String {
        let shown = names.count > 3 ? Array(names.prefix(2)) + ["\(names.count - 2) others"] : names
        return "\(shown.formatted()) \(names.count == 1 ? "is" : "are")"
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

/// What the team looked like last time, for when there's no signal.
struct TeamCache: Codable {
    let season: TeamStats
    let lastMatch: TeamMatchMinutes?

    private static func url(_ code: String) -> URL {
        AppGroup.containerURL.appendingPathComponent("team-\(code).json")
    }

    static func load(_ code: String) -> TeamCache? {
        (try? Data(contentsOf: url(code))).flatMap { try? JSONDecoder().decode(TeamCache.self, from: $0) }
    }

    func save(_ code: String) {
        try? JSONEncoder().encode(self).write(to: Self.url(code), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func remove(_ code: String) {
        try? FileManager.default.removeItem(at: url(code))
    }
}

// MARK: - Settings

extension SettingsStore {
    func team(_ code: String) -> TeamMembership? { teamMemberships.first { $0.code == code } }

    func updateTeam(_ code: String, _ change: (inout TeamMembership) -> Void) {
        var memberships = teamMemberships
        guard let index = memberships.firstIndex(where: { $0.code == code }) else { return }
        change(&memberships[index])
        teamMemberships = memberships
    }

    /// What this player calls the team, else what the server calls it. Never the code: a code isn't a name.
    func teamName(_ code: String, sharedName: String?) -> String? {
        [team(code)?.name, sharedName].compactMap { $0 }.first { !$0.isEmpty }
    }

    func invite(_ code: String, sharedName: String?) -> TeamInvite {
        TeamInvite(code: code, name: teamName(code, sharedName: sharedName), captain: team(code)?.captainName)
    }

    func isMe(_ name: String) -> Bool {
        let mine = playerName.trimmingCharacters(in: .whitespaces)
        return !mine.isEmpty && name.localizedCaseInsensitiveCompare(mine) == .orderedSame
    }

    func isCaptain(_ name: String, of code: String) -> Bool {
        team(code)?.captainName.map { name.localizedCaseInsensitiveCompare($0) == .orderedSame } ?? false
    }

    /// Adds a team and shows it. New matches go to the first team joined until the player says otherwise.
    func enterTeam(_ invite: TeamInvite) {
        var memberships = teamMemberships
        let isFirst = memberships.isEmpty
        if let index = memberships.firstIndex(where: { $0.code == invite.code }) {
            memberships[index].name = invite.name ?? memberships[index].name
            memberships[index].captainName = invite.captain ?? memberships[index].captainName
        } else {
            memberships.append(TeamMembership(code: invite.code, name: invite.name, captainName: invite.captain, joinedAt: Date()))
        }
        teamMemberships = memberships
        if isFirst { teamCode = invite.code }
        leftTeams.removeAll { $0 == invite.code }
        viewedTeam = invite.code
    }

    /// The teams this player captains follow their new name.
    func rename(player newName: String) {
        for membership in teamMemberships where membership.captainName == playerName && !newName.isEmpty {
            updateTeam(membership.code) { $0.captainName = newName }
        }
        playerName = newName
    }
}

extension AppEnvironment {
    /// Off the team here at once, and on the server as soon as it can be told.
    func leaveTeam(_ code: String) {
        settings.teamMemberships = settings.teamMemberships.filter { $0.code != code }
        settings.confirmedTeams.removeAll { $0 == code }
        settings.leftTeams.append(code)
        uploads.discardUploads(teamCode: code)
        TeamCache.remove(code)
        TeamPlan.remove(code)
        FormationBoard.remove(code)
        settingsChanged()
        Task { await TeamService.tellServerAboutTeams() }
    }

    func joinTeam(_ invite: TeamInvite, as playerName: String) {
        settings.rename(player: playerName)
        settings.enterTeam(invite)
        settingsChanged()
        Task { await TeamService.tellServerAboutTeams() }
    }
}
