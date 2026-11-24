// TeamRosterViews.swift
// MatchTracker

import SwiftUI
import MatchTrackerKit

// MARK: - Metric

enum TeamMetric: String, CaseIterable, Identifiable {
    case distance, minutes, goals, assists, sprints

    var id: String { rawValue }

    var title: String {
        switch self {
        case .distance: return "Distance"
        case .minutes: return "Minutes"
        case .goals: return "Goals"
        case .assists: return "Assists"
        case .sprints: return "Sprints"
        }
    }

    /// Nil when nobody measured it, which is not the same as zero.
    func value(_ player: TeamStats.Player) -> Double? {
        switch self {
        case .distance: return player.totalDistanceMeters > 0 ? player.totalDistanceMeters : nil
        case .minutes: return player.minutesPlayed
        case .goals: return Double(player.goals)
        case .assists: return Double(player.assists)
        case .sprints: return player.sprints.map(Double.init)
        }
    }

    func text(_ value: Double) -> String {
        switch self {
        case .distance: return UnitSystem.current.distance(value).text
        case .minutes: return "\(Int(value.rounded())) min"
        case .goals, .assists, .sprints: return "\(Int(value.rounded()))"
        }
    }

    func spoken(_ value: Double) -> String {
        switch self {
        case .distance: return UnitSystem.current.distance(value).spoken
        case .minutes: return "\(Int(value.rounded())) minutes"
        case .goals, .assists, .sprints:
            let count = Int(value.rounded())
            return count == 1 ? "1 \(rawValue.dropLast())" : "\(count) \(rawValue)"
        }
    }

    struct Standing: Identifiable {
        let name: String
        let rank: Int
        let value: Double
        var id: String { name }
    }

    /// Best first, ties sharing a rank. Players with nothing to rank are left out.
    func standings(_ players: [TeamStats.Player]) -> [Standing] {
        let entries: [(name: String, value: Double)] = players.compactMap { player in
            guard let value = value(player), value > 0 else { return nil }
            return (player.name, value)
        }
        let ranked = entries.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return ranked.map { name, value in
            Standing(name: name, rank: 1 + ranked.filter { $0.value > value }.count, value: value)
        }
    }
}

// MARK: - Leaderboard

/// The leaderboard as list sections, including its loading, empty and failed states.
struct TeamLeaderboardSections: View {
    let team: TeamModel
    let showsSquadLink: Bool

    @EnvironmentObject private var settings: SettingsStore
    @AppStorage("teamLeaderboardMetric") private var metric: TeamMetric = .distance

    private static let homeLimit = 5

    var body: some View {
        switch team.phase {
        case .loading:
            Section {
                ForEach(0..<5, id: \.self) { index in
                    LeaderboardRow(standing: .init(name: "Player Name", rank: index + 1, value: 10_000), best: 12_000,
                                   metric: .distance, isMe: false)
                }
                .redacted(reason: .placeholder)
                .accessibilityHidden(true)
            }
        case .failed(let message):
            Section {
                ContentUnavailableView {
                    Label("Couldn't load your team", systemImage: "wifi.slash")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await team.load(code: settings.teamCode) } }
                        .buttonStyle(.borderedProminent)
                }
            }
        case .loaded where team.season?.players.isEmpty ?? true:
            Section {
                ContentUnavailableView {
                    Label("No matches yet", systemImage: "figure.soccer")
                } description: {
                    Text("Teammates appear here after their first match with MatchTracker. Invite them to get started.")
                } actions: {
                    ShareLink(item: TeamInvite(code: settings.teamCode, name: settings.teamName(orNil: team.season?.teamName)).message) {
                        Text("Invite Teammates")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        case .loaded:
            leaderboard
        }
    }

    @ViewBuilder private var leaderboard: some View {
        let isThisWeek = !(team.week?.players.isEmpty ?? true)
        let players = (isThisWeek ? team.week : team.season)?.players ?? []
        let standings = metric.standings(players)
        Section {
            header(isThisWeek ? "This week" : TeamModel.seasonTitle,
                   note: !isThisWeek && team.week != nil ? "Nobody has played yet this week." : nil)
                .listRowSeparator(.hidden, edges: .bottom)
            ForEach(visible(standings)) { standing in
                LeaderboardRow(standing: standing, best: standings.first?.value ?? 0, metric: metric,
                               isMe: settings.isMe(standing.name))
            }
            if standings.isEmpty {
                Text("No \(metric.title.lowercased()) recorded yet.")
                    .foregroundStyle(.secondary)
            }
            if showsSquadLink {
                NavigationLink(value: TeamDestination.squad) {
                    LabeledContent("Whole squad", value: "\(team.season?.players.count ?? players.count)")
                }
            }
        }
    }

    private func header(_ title: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(title).font(.title2.bold())
                    Spacer()
                    metricPicker
                }
                VStack(alignment: .leading) {
                    Text(title).font(.title2.bold())
                    // A menu picker insets its label; line it up with the rest.
                    metricPicker.padding(.leading, -12)
                }
            }
            if let note {
                Text(note).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var metricPicker: some View {
        Picker("Ranked by", selection: $metric) {
            ForEach(TeamMetric.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }

    /// The top five, and you if you're further down.
    private func visible(_ standings: [TeamMetric.Standing]) -> [TeamMetric.Standing] {
        guard showsSquadLink, standings.count > Self.homeLimit else { return standings }
        let top = standings.prefix(Self.homeLimit)
        guard let mine = standings.first(where: { settings.isMe($0.name) }), !top.contains(where: { $0.id == mine.id }) else {
            return Array(top)
        }
        return top + [mine]
    }
}

struct LeaderboardRow: View {
    let standing: TeamMetric.Standing
    let best: Double
    let metric: TeamMetric
    let isMe: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isLeader: Bool { standing.rank == 1 }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        VStack(alignment: .leading, spacing: 8) {
            layout {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(standing.rank)")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 22, alignment: .leading)
                    TeamPlayerName(name: standing.name, isMe: isMe)
                        .font(isLeader ? .title3.bold() : .body)
                }
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                Text(metric.text(standing.value))
                    .font(.system(isLeader ? .title2 : .body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            ProgressView(value: best > 0 ? standing.value / best : 0)
                .tint(isMe ? Theme.turf : Color(.systemGray2))
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(standing.rank). \(standing.name)\(isMe ? ", you" : "")")
        .accessibilityValue(metric.spoken(standing.value))
    }
}

/// A player's name, marked in words as well as green when it's you.
struct TeamPlayerName: View {
    let name: String
    var isMe: Bool?

    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        if isMe ?? settings.isMe(name) {
            Text("\(name) \(Text("You").foregroundStyle(Theme.turf))")
        } else {
            Text(name)
        }
    }
}

// MARK: - Squad

struct TeamSquadView: View {
    let team: TeamModel

    var body: some View {
        List {
            Section {
                ForEach(players, id: \.name) { player in
                    NavigationLink(value: TeamDestination.player(player.name)) {
                        VStack(alignment: .leading, spacing: 2) {
                            TeamPlayerName(name: player.name)
                            Text(summary(player))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(TeamModel.seasonTitle)
            } footer: {
                Text("Everyone who has shared a match with the team this season.")
            }
        }
        .navigationTitle("Squad")
    }

    private var players: [TeamStats.Player] {
        (team.season?.players ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func summary(_ player: TeamStats.Player) -> String {
        let matches = player.matchesPlayed == 1 ? "1 match" : "\(player.matchesPlayed) matches"
        guard let minutes = player.minutesPlayed else { return matches }
        return "\(matches), \(Int(minutes.rounded())) minutes"
    }
}

struct TeamPlayerView: View {
    let name: String
    let team: TeamModel

    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        List {
            if let player = team.week?.players.first(where: { $0.name == name }) {
                Section("This week") { rows(player) }
            }
            if let player = team.season?.players.first(where: { $0.name == name }) {
                Section(TeamModel.seasonTitle) { rows(player) }
            }
        }
        .readableFormWidth()
        .background(Color(.systemGroupedBackground))
        .navigationTitle(settings.isMe(name) ? "\(name) (You)" : name)
    }

    @ViewBuilder
    private func rows(_ player: TeamStats.Player) -> some View {
        LabeledContent("Matches", value: "\(player.matchesPlayed)")
        ForEach(TeamMetric.allCases) { metric in
            LabeledContent(metric.title) {
                Text(metric.value(player).map(metric.text) ?? "—")
                    .monospacedDigit()
                    .accessibilityLabel(metric.value(player).map(metric.spoken) ?? "Not recorded")
            }
        }
    }
}

// MARK: - Initials

enum RosterAvatar {
    static func initials(from name: String) -> String {
        let parts = name.split { $0 == " " || $0 == "." }
        if parts.count >= 2 { return "\(parts[0].prefix(1))\(parts[parts.count - 1].prefix(1))".uppercased() }
        return parts.first.map { String($0.prefix(2)).uppercased() } ?? "?"
    }

    /// "Maya", or "M. B." as it stands when that's all there is.
    static func shortName(_ name: String) -> String {
        name.contains(".") ? name : String(name.split(separator: " ").first ?? "?")
    }
}
