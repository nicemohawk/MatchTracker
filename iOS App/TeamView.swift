// TeamView.swift
// MatchTracker

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

    enum LoadState {
        case idle, loading, loaded(TeamStats), failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Your Team") {
                    TextField("Player name", text: $playerName)
                        .textInputAutocapitalization(.words)
                    TextField("Team code", text: $teamCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Button("Save & Refresh") { commitAndLoad() }
                        .disabled(teamCode.isEmpty)
                }

                membershipsSection

                teamFeaturesSection

                rosterSection
            }
            .navigationTitle("Team")
            .onAppear {
                teamCode = settings.teamCode
                playerName = settings.playerName
                if !teamCode.isEmpty { Task { await load() } }
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView(entitlements: entitlements)
            }
        }
    }

    /// Formation + chat, both team-subscription features.
    @ViewBuilder
    private var teamFeaturesSection: some View {
        if !settings.teamCode.isEmpty {
            Section("Team Features") {
                if entitlements.entitledToTeam {
                    NavigationLink {
                        FormationView(teamCode: settings.teamCode)
                    } label: {
                        Label("Formation", systemImage: "square.grid.3x3.middle.filled")
                    }
                    NavigationLink {
                        TeamChatView()
                    } label: {
                        Label("Match Chat", systemImage: "bubble.left.and.bubble.right")
                    }
                } else {
                    Button {
                        showingPaywall = true
                    } label: {
                        Label("Unlock formation, chat & live dashboard", systemImage: "lock")
                    }
                }
            }
        }
    }

    /// Multi-team memberships: the starred team is the default for uploads and the watch.
    /// A second membership is a team-subscription feature.
    @ViewBuilder
    private var membershipsSection: some View {
        let memberships = settings.teamMemberships
        if !memberships.isEmpty || entitlements.entitledToTeam {
            Section("My Teams") {
                ForEach(memberships) { membership in
                    membershipRow(membership)
                }
                HStack {
                    TextField("Add team code", text: $newTeamCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Button("Add") { addMembership() }
                        .disabled(newTeamCode.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !entitlements.entitledToTeam && memberships.count >= 1 {
                    Button {
                        showingPaywall = true
                    } label: {
                        Label("Multiple teams require Team features", systemImage: "lock")
                            .font(.caption)
                    }
                }
            }
        }
    }

    private func membershipRow(_ membership: TeamMembership) -> some View {
        HStack {
            Button {
                settings.teamCode = membership.code
                teamCode = membership.code
                environment.settingsChanged()
                Task { await load() }
            } label: {
                Image(systemName: membership.code == settings.teamCode ? "star.fill" : "star")
                    .foregroundStyle(.yellow)
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading) {
                Text(membership.code).font(.body.monospaced())
                if let name = membership.name { Text(name).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            // Initials-only display for this team (minors privacy; enforced server-side too).
            Toggle("Initials", isOn: initialsBinding(for: membership))
                .labelsHidden()
                .toggleStyle(.button)
                .font(.caption2)

            Button(role: .destructive) {
                settings.teamMemberships.removeAll { $0.code == membership.code }
                environment.settingsChanged()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    private func initialsBinding(for membership: TeamMembership) -> Binding<Bool> {
        Binding(
            get: { settings.teamMemberships.first { $0.code == membership.code }?.displayInitialsOnly ?? false },
            set: { newValue in
                var memberships = settings.teamMemberships
                if let index = memberships.firstIndex(where: { $0.code == membership.code }) {
                    memberships[index].displayInitialsOnly = newValue
                    settings.teamMemberships = memberships
                }
            }
        )
    }

    private func addMembership() {
        let code = newTeamCode.trimmingCharacters(in: .whitespaces).uppercased()
        guard !code.isEmpty else { return }
        var memberships = settings.teamMemberships
        guard !memberships.contains(where: { $0.code == code }) else { newTeamCode = ""; return }
        // The second team (and beyond) is gated behind the team subscription.
        if !memberships.isEmpty && !entitlements.entitledToTeam {
            showingPaywall = true
            return
        }
        memberships.append(TeamMembership(code: code, name: nil, displayInitialsOnly: false))
        settings.teamMemberships = memberships
        newTeamCode = ""
        if settings.teamCode.isEmpty {
            settings.teamCode = code
            teamCode = code
        }
        environment.settingsChanged()
    }

    @ViewBuilder
    private var rosterSection: some View {
        switch loadState {
        case .idle:
            Section {
                ContentUnavailableView(
                    "No Team Code",
                    systemImage: "person.3",
                    description: Text("Enter a team code to see roster stats.")
                )
            }
        case .loading:
            Section { HStack { Spacer(); ProgressView(); Spacer() } }
        case .loaded(let stats) where stats.players.isEmpty:
            Section("Roster") {
                ContentUnavailableView(
                    "No Teammates Yet",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Stats appear once teammates upload matches.")
                )
            }
        case .loaded(let stats):
            Section("Roster · \(stats.teamCode)") {
                RosterHeader()
                ForEach(stats.players, id: \.name) { player in
                    RosterRow(player: player)
                }
            }
        case .failed(let message):
            Section("Roster") {
                Text(message).font(.callout).foregroundStyle(.secondary)
                localFallback
            }
        }
    }

    /// Local-only aggregates from this device's matches when the backend is unavailable.
    private var localFallback: some View {
        let count = matches.matches.count
        let distance = matches.matches.reduce(0.0) { $0 + $1.distanceMeters }
        let goals = matches.matches.reduce(0) { total, summary in
            total + (summary.record?.events.filter { $0.kind == .goalMine }.count ?? 0)
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Your local totals").font(.caption.weight(.semibold))
            HStack {
                Text("\(count) matches")
                Spacer()
                Text(MatchFormat.distance(distance))
                Spacer()
                Text("\(goals) goals")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func commitAndLoad() {
        settings.playerName = playerName
        settings.teamCode = teamCode.uppercased()
        teamCode = settings.teamCode
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

struct RosterHeader: View {
    var body: some View {
        HStack {
            Text("Player").frame(maxWidth: .infinity, alignment: .leading)
            Text("M").frame(width: 30, alignment: .trailing)
            Text("Min").frame(width: 38, alignment: .trailing)
            Text("km").frame(width: 46, alignment: .trailing)
            Text("WR").frame(width: 34, alignment: .trailing)
            Text("Spr").frame(width: 34, alignment: .trailing)
            Text("G/A").frame(width: 42, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
    }
}

struct RosterRow: View {
    let player: TeamStats.Player

    var body: some View {
        HStack {
            Text(player.name).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
            Text("\(player.matchesPlayed)").frame(width: 30, alignment: .trailing)
            Text(player.minutesPlayed.map { String(format: "%.0f", $0) } ?? "—").frame(width: 38, alignment: .trailing)
            Text(String(format: "%.1f", player.totalDistanceMeters / 1000)).frame(width: 46, alignment: .trailing)
            Text("\(Int(player.averageWorkrateScore))").frame(width: 34, alignment: .trailing)
            Text(player.sprints.map { "\($0)" } ?? "—").frame(width: 34, alignment: .trailing)
            Text("\(player.goals)/\(player.assists)").frame(width: 42, alignment: .trailing)
        }
        .font(.caption.monospacedDigit())
    }
}
