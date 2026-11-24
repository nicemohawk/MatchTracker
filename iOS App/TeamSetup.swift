// TeamSetup.swift
// MatchTracker

import SwiftUI
import MatchTrackerKit

// MARK: - Join

/// Joining by pasted invite, typed code, or a link that has already been opened.
struct TeamJoinSheet: View {
    var invite: TeamInvite?

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var pasted = ""
    @State private var playerName = ""

    private var joining: TeamInvite? { invite ?? TeamInvite(pasted: pasted) }
    private var trimmedPlayerName: String { playerName.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let invite {
                        Text(invite.name ?? "Team \(invite.code)").font(.title2.bold())
                        if let captain = invite.captain { LabeledContent("Captain", value: captain) }
                    } else {
                        TextField("Team code or invite message", text: $pasted, axis: .vertical)
                            .lineLimit(1...4)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        PasteButton(payloadType: String.self) { strings in
                            Task { @MainActor in pasted = strings.first ?? pasted }
                        }
                    }
                } footer: {
                    if let name = joining?.name, invite == nil {
                        Text("You're joining \(name).")
                    } else if !pasted.isEmpty && joining == nil {
                        Text("That doesn't look like a team code. Codes are letters and numbers, with no spaces.")
                    } else if invite == nil {
                        Text("Ask a teammate to send you an invite from their Team tab.")
                    }
                }
                TeamPlayerNameSection(name: $playerName)
                TeamSharingSection()
            }
            .navigationTitle("Join a Team")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Join", action: join).disabled(joining == nil || trimmedPlayerName.isEmpty)
                }
            }
            .onAppear { playerName = settings.playerName }
        }
    }

    private func join() {
        guard let joining else { return }
        environment.joinTeam(joining, as: trimmedPlayerName)
        dismiss()
    }
}

// MARK: - Create

/// Starting a team: a name, then the invite to send.
struct TeamCreateSheet: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var teamName = ""
    @State private var playerName = ""
    @State private var created: TeamInvite?

    private var trimmedName: String { teamName.trimmingCharacters(in: .whitespaces) }
    private var trimmedPlayerName: String { playerName.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            if let created {
                TeamReadyView(invite: created) { dismiss() }
            } else {
                form
            }
        }
    }

    private var form: some View {
        Form {
            Section {
                TextField("Team name", text: $teamName)
                    .textInputAutocapitalization(.words)
            } footer: {
                Text("You're the captain. You'll get an invite to send to your teammates.")
            }
            TeamPlayerNameSection(name: $playerName)
            TeamSharingSection()
        }
        .navigationTitle("Start a Team")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Start", action: create).disabled(trimmedName.isEmpty || trimmedPlayerName.isEmpty)
            }
        }
        .onAppear { playerName = settings.playerName }
    }

    private func create() {
        let invite = TeamInvite(code: TeamInvite.newCode(), name: trimmedName, captain: trimmedPlayerName)
        environment.joinTeam(invite, as: trimmedPlayerName)
        withAnimation { created = invite }
    }
}

/// The invite, the moment there's a team to invite people to.
struct TeamReadyView: View {
    let invite: TeamInvite
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text("\(invite.name ?? "Your team") is ready").font(.largeTitle.bold())
                    Text("Send the invite to your team's group chat. Teammates tap the link, or paste the message in their Team tab.")
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 4) {
                    Text(invite.code)
                        .font(.system(.largeTitle, design: .rounded).bold())
                        .monospaced()
                        .textSelection(.enabled)
                        .accessibilityLabel("Team code \(invite.code.map(String.init).joined(separator: " "))")
                    Text("Or read them the code").font(.subheadline).foregroundStyle(.secondary)
                }
                Text("Anyone with the code can join and see the team, so send it to people you play with.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.top, 32)
            .readableWidth(560)
        }
        .bottomActionBar {
            ShareLink(item: invite.message) { Text("Send Invite") }
                .buttonStyle(.primaryAction)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) }
        }
    }
}

// MARK: - Shared pieces

/// Where a new member's matches will go, and who sees what.
private struct TeamSharingSection: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Section {
            NavigationLink("Who Sees What") { TeamPrivacyView() }
        } footer: {
            if let current = settings.team(settings.teamCode) {
                Text("New matches keep going to \(current.name ?? current.code). You can change that in Manage Team.")
            } else {
                Text("Matches you record from now on are shared with this team. Ones you've already played stay yours.")
            }
        }
    }
}

struct TeamPrivacyView: View {
    var body: some View {
        List {
            Section("Your team sees") {
                Text("Your name, exactly as you typed it")
                Text("Minutes, distance, sprints, goals and assists")
                Text("Where you usually play on the pitch")
                Text("Goals, cards, flags and notes you log")
                Text("While you're playing: distance, and whether you're on the pitch")
            }
            Section {
                Text("Heart rate")
                Text("Your route and heat map")
                Text("Matches from before you joined, or after you leave")
            } header: {
                Text("Your team doesn't see")
            } footer: {
                Text("A shared match's route, average heart rate and effort also go to the MatchTracker server, which uses the route to map fields. They aren't shown to your team.")
            }
            Section {
                Text("Anyone with the team code can join and see all of this, so only send it to people you play with. For a child, initials or a nickname are enough.")
                Text("Leaving stops sharing. Delete My Server Data in Settings removes what you've already shared.")
            }
        }
        .readableFormWidth()
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Who Sees What")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TeamPlayerNameSection: View {
    @Binding var name: String

    var body: some View {
        Section {
            LabeledContent("Your name") {
                TextField("Name or initials", text: $name)
                    .textContentType(.name)
                    .multilineTextAlignment(.trailing)
            }
        } footer: {
            Text("Teammates see exactly this next to your matches.")
        }
    }
}

// MARK: - Manage

struct TeamManageSheet: View {
    let sharedName: String?

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    /// The team this sheet is about; fields are saved to it even once another is on screen.
    @State private var code = ""
    @State private var teamName = ""
    @State private var playerName = ""
    @State private var captainName = ""
    @State private var leaving: TeamMembership?
    @State private var page: Page?

    private enum Page: String, Identifiable {
        case join, create
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                teamSection
                TeamPlayerNameSection(name: $playerName)
                rolesSection
                sharingSection
                teamsSection
                Section {
                    NavigationLink("Who Sees What") { TeamPrivacyView() }
                    Button("Leave \(settings.teamName(code, sharedName: sharedName) ?? "Team")", role: .destructive) {
                        leaving = settings.team(code)
                    }
                }
            }
            .navigationTitle("Manage Team")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear(perform: fill)
            .onChange(of: settings.viewedTeam) {
                save()
                fill()
            }
            .onDisappear(perform: save)
            .alert(
                "Leave \(leaving.map(title) ?? "this team")?",
                isPresented: Binding(get: { leaving != nil }, set: { if !$0 { leaving = nil } }),
                presenting: leaving
            ) { membership in
                Button("Leave Team", role: .destructive) { leave(membership) }
                Button("Cancel", role: .cancel) {}
            } message: { membership in
                Text(leavingMessage(membership))
            }
            .sheet(item: $page) { page in
                switch page {
                case .join: TeamJoinSheet()
                case .create: TeamCreateSheet()
                }
            }
        }
    }

    // MARK: Sections

    private var teamSection: some View {
        Section {
            LabeledContent("Team name") {
                TextField("Team name", text: $teamName)
                    .textInputAutocapitalization(.words)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Team code") {
                Text(code).textSelection(.enabled)
            }
            ShareLink(item: settings.invite(code, sharedName: sharedName).message) {
                Text("Invite Teammates")
            }
        } footer: {
            Text("A new name shows on this device and on invites you send. Teammates who've already joined keep theirs.")
        }
    }

    private var rolesSection: some View {
        Section {
            LabeledContent("Captain") {
                TextField("Nobody", text: $captainName)
                    .textInputAutocapitalization(.words)
                    .multilineTextAlignment(.trailing)
            }
            Toggle("I coach this team", isOn: Binding(
                get: { settings.team(code)?.isCoach ?? false },
                set: { isCoach in settings.updateTeam(code) { $0.isCoach = isCoach } }))
        } footer: {
            Text("Whoever starts a team is its captain. Type another name to hand over: it goes on invites you send from now on. A team doesn't need a coach. Coaching puts playing time first on your own screen, and changes nothing for anyone else.")
        }
    }

    private var sharingSection: some View {
        Section {
            Picker("Share new matches with", selection: Binding(
                get: { settings.teamCode },
                set: {
                    settings.teamCode = $0
                    environment.settingsChanged()
                })) {
                ForEach(settings.teamMemberships) { Text(title($0)).tag($0.code) }
                Text("Nobody").tag("")
            }
        } footer: {
            Text("You can see your teams either way.")
        }
    }

    private var teamsSection: some View {
        Section("Your teams") {
            ForEach(settings.teamMemberships) { membership in
                teamRow(membership)
            }
            Button("Join Another Team") { page = .join }
            Button("Start a Team") { page = .create }
        }
    }

    private func teamRow(_ membership: TeamMembership) -> some View {
        let isCurrent = membership.code == code
        return Button {
            settings.viewedTeam = membership.code
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(title(membership))
                    if membership.name == nil {
                        Text("Code \(membership.code)").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isCurrent {
                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Theme.turf)
                }
            }
            .contentShape(Rectangle())
        }
        .tint(.primary)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .swipeActions {
            Button("Leave", role: .destructive) { leaving = membership }
        }
    }

    private func title(_ membership: TeamMembership) -> String {
        if let name = membership.name, !name.isEmpty { return name }
        return (membership.code == code ? sharedName : nil) ?? "Team \(membership.code)"
    }

    private func leavingMessage(_ membership: TeamMembership) -> String {
        let next = membership.code == settings.teamCode ? settings.teamMemberships.first { $0.code != membership.code } : nil
        let sharing = next.map { "Your new matches will go to \(title($0)) instead." } ?? "Your new matches won't be shared with them."
        return "\(sharing) Matches you've already shared stay with the team, and it carries on without you. You can rejoin with the code."
    }

    // MARK: Actions

    private func fill() {
        code = settings.viewedTeam
        teamName = settings.teamName(code, sharedName: sharedName) ?? ""
        playerName = settings.playerName
        captainName = settings.team(code)?.captainName ?? ""
    }

    /// Saved once, on the way out, so half-typed names never reach the watch.
    private func save() {
        guard settings.team(code) != nil else { return }
        let newTeamName = teamName.trimmingCharacters(in: .whitespaces)
        let newPlayerName = playerName.trimmingCharacters(in: .whitespaces)
        let newCaptain = captainName.trimmingCharacters(in: .whitespaces)
        if newCaptain != settings.team(code)?.captainName ?? "" {
            settings.updateTeam(code) { $0.captainName = newCaptain.isEmpty ? nil : newCaptain }
        }
        if !newTeamName.isEmpty && newTeamName != settings.teamName(code, sharedName: sharedName) {
            settings.updateTeam(code) { $0.name = newTeamName }
        }
        // A team knows a player by their name, so there's always one.
        if !newPlayerName.isEmpty && newPlayerName != settings.playerName {
            settings.rename(player: newPlayerName)
            environment.settingsChanged()
        }
    }

    private func leave(_ membership: TeamMembership) {
        let isCurrent = membership.code == code
        environment.leaveTeam(membership.code)
        if isCurrent { dismiss() }
    }
}
