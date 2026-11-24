// TeamSetup.swift
// MatchTracker

import SwiftUI
import MatchTrackerKit

// MARK: - Join

struct TeamJoinSheet: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var pasted = ""
    @State private var playerName = ""

    private var invite: TeamInvite? { TeamInvite(pasted: pasted) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Team code or invite message", text: $pasted, axis: .vertical)
                        .lineLimit(1...4)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    PasteButton(payloadType: String.self) { strings in
                        Task { @MainActor in pasted = strings.first ?? pasted }
                    }
                } footer: {
                    if let invite, let name = invite.name {
                        Text("You're joining \(name).")
                    } else if !pasted.isEmpty && invite == nil {
                        Text("That doesn't look like a team code. Codes are letters and numbers, with no spaces.")
                    } else {
                        Text("Ask a teammate to send you an invite from their Team tab.")
                    }
                }
                TeamPlayerNameSection(name: $playerName)
            }
            .navigationTitle("Join a Team")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Join", action: join).disabled(invite == nil)
                }
            }
            .onAppear { playerName = settings.playerName }
        }
    }

    private func join() {
        guard let invite else { return }
        settings.playerName = playerName.trimmingCharacters(in: .whitespaces)
        settings.enterTeam(code: invite.code, name: invite.name)
        environment.settingsChanged()
        dismiss()
    }
}

// MARK: - Create

struct TeamCreateSheet: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var teamName = ""
    @State private var playerName = ""

    private var trimmedName: String { teamName.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Team name", text: $teamName)
                        .textInputAutocapitalization(.words)
                } footer: {
                    Text("You'll get an invite to send to your teammates.")
                }
                TeamPlayerNameSection(name: $playerName)
            }
            .navigationTitle("Create a Team")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: create).disabled(trimmedName.isEmpty)
                }
            }
            .onAppear { playerName = settings.playerName }
        }
    }

    private func create() {
        settings.playerName = playerName.trimmingCharacters(in: .whitespaces)
        settings.enterTeam(code: TeamInvite.newCode(), name: trimmedName)
        environment.settingsChanged()
        dismiss()
    }
}

private struct TeamPlayerNameSection: View {
    @Binding var name: String

    var body: some View {
        Section {
            LabeledContent("Your name") {
                TextField("First and last", text: $name)
                    .textContentType(.name)
                    .multilineTextAlignment(.trailing)
            }
        } footer: {
            Text("Teammates see this next to your matches. Use initials if you'd rather not share your full name.")
        }
    }
}

// MARK: - Manage

struct TeamManageSheet: View {
    let sharedName: String?

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(\.dismiss) private var dismiss

    @State private var teamName = ""
    @State private var playerName = ""
    @State private var leaving: TeamMembership?
    @State private var page: Page?

    private enum Page: String, Identifiable {
        case join, create, plan
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Team name") {
                        TextField("Team name", text: $teamName)
                            .textInputAutocapitalization(.words)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Team code") {
                        Text(settings.teamCode).textSelection(.enabled)
                    }
                    ShareLink(item: TeamInvite(code: settings.teamCode, name: settings.teamName(orNil: sharedName)).message) {
                        Text("Invite Teammates")
                    }
                }
                TeamPlayerNameSection(name: $playerName)
                Section {
                    ForEach(settings.teamMemberships) { membership in
                        teamRow(membership)
                    }
                    addTeamButtons
                } header: {
                    Text("Your teams")
                } footer: {
                    Text("New matches are shared with the team that's checked.")
                }
                Section {
                    Button("Leave \(settings.teamName(sharedName: sharedName))", role: .destructive) {
                        leaving = settings.teamMemberships.first { $0.code == settings.teamCode }
                            ?? TeamMembership(code: settings.teamCode)
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
            .onChange(of: settings.teamCode) { fill() }
            .onDisappear(perform: save)
            .alert(
                "Leave \(leaving.map(title) ?? "this team")?",
                isPresented: Binding(get: { leaving != nil }, set: { if !$0 { leaving = nil } }),
                presenting: leaving
            ) { membership in
                Button("Leave Team", role: .destructive) { leave(membership) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Your new matches won't be shared with them. Matches you've already shared stay with the team. You can rejoin with the code.")
            }
            .sheet(item: $page) { page in
                switch page {
                case .join: TeamJoinSheet()
                case .create: TeamCreateSheet()
                case .plan: PaywallView(entitlements: entitlements)
                }
            }
        }
    }

    private func teamRow(_ membership: TeamMembership) -> some View {
        let isCurrent = membership.code == settings.teamCode
        return Button {
            save()
            settings.enterTeam(code: membership.code, name: nil)
            environment.settingsChanged()
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

    @ViewBuilder private var addTeamButtons: some View {
        Button("Join Another Team") { page = entitlements.entitledToTeam ? .join : .plan }
        Button("Create a Team") { page = entitlements.entitledToTeam ? .create : .plan }
        if !entitlements.entitledToTeam {
            Text("Playing for more than one team is part of the Team plan.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func title(_ membership: TeamMembership) -> String {
        if let name = membership.name, !name.isEmpty { return name }
        return membership.code == settings.teamCode ? settings.teamName(sharedName: sharedName) : "Team without a name"
    }

    // MARK: Actions

    private func fill() {
        teamName = settings.teamName(orNil: sharedName) ?? ""
        playerName = settings.playerName
    }

    /// Saved once, on the way out, so half-typed names never reach the watch.
    private func save() {
        guard !settings.teamCode.isEmpty else { return }
        let newTeamName = teamName.trimmingCharacters(in: .whitespaces)
        let newPlayerName = playerName.trimmingCharacters(in: .whitespaces)
        let isTeamRenamed = !newTeamName.isEmpty && newTeamName != settings.teamName(orNil: sharedName)
        guard isTeamRenamed || newPlayerName != settings.playerName else { return }
        if isTeamRenamed { settings.enterTeam(code: settings.teamCode, name: newTeamName) }
        settings.playerName = newPlayerName
        environment.settingsChanged()
    }

    private func leave(_ membership: TeamMembership) {
        let isCurrent = membership.code == settings.teamCode
        let remaining = settings.teamMemberships.filter { $0.code != membership.code }
        settings.teamMemberships = remaining
        environment.settingsChanged()
        if isCurrent { dismiss() }
    }
}
