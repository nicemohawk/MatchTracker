// TeamJoinCard.swift
// MatchTracker
//
// The Team-tab setup surfaces: an inviting "Join your team" card before a code is set, a compact
// team header once configured, plus the My-Teams membership manager and the gated team features.
// Split out of TeamView so the leaderboard stays the star of the screen.

import SwiftUI
import MatchTrackerKit

// MARK: - Join card

/// Full-width invitation shown when no team code is set yet. Carries the player-name + code fields
/// and the join button that the old top-of-Form section used to hold.
struct JoinTeamCard: View {
    @Binding var playerName: String
    @Binding var teamCode: String
    var onJoin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "person.3.sequence.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.turf)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Join your team")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                    Text("Enter your club's code to see the squad leaderboard and stack up against teammates.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 10) {
                field("Player name", text: $playerName, autocap: .words, mono: false)
                field("Team code", text: $teamCode, autocap: .characters, mono: true)
            }

            Button(action: onJoin) {
                Text("Join Team")
                    .font(.system(.body, design: .rounded).weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(teamCode.isEmpty ? Color.secondary : Theme.turf)
                    .background(
                        Capsule().fill(Theme.chipFill(teamCode.isEmpty ? Theme.bench : Theme.turf))
                    )
                    .overlay(
                        Capsule().strokeBorder(Theme.chipStroke(teamCode.isEmpty ? Theme.bench : Theme.turf), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(teamCode.isEmpty)
        }
        .padding(18)
        .themedCard()
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Theme.chipStroke(Theme.turf), lineWidth: 1)
        )
    }

    private func field(_ prompt: String, text: Binding<String>, autocap: TextInputAutocapitalization, mono: Bool) -> some View {
        TextField(prompt, text: text)
            .textInputAutocapitalization(autocap)
            .autocorrectionDisabled(mono)
            .font(mono ? .body.monospaced() : .body)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.surfaceStroke, lineWidth: 1)
            )
    }
}

// MARK: - Compact team header

/// Once a team is joined the setup collapses to this: the active code, live member count, and a
/// refresh control. Editing/switching teams moves to the My Teams manager below.
struct TeamHeaderBar: View {
    let teamCode: String
    let memberCount: Int?
    let isLoading: Bool
    var onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.title2)
                .foregroundStyle(Theme.turf)
            VStack(alignment: .leading, spacing: 2) {
                Text(teamCode)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .monospaced()
                Text(memberCountLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.turf)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Theme.chipFill(Theme.turf)))
                    .overlay(Circle().strokeBorder(Theme.chipStroke(Theme.turf), lineWidth: 1))
                    .rotationEffect(.degrees(isLoading ? 360 : 0))
                    .animation(isLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isLoading)
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
        }
        .padding(16)
        .themedCard()
    }

    private var memberCountLabel: String {
        guard let memberCount else { return "Loading roster…" }
        return "\(memberCount) \(memberCount == 1 ? "member" : "members")"
    }
}

// MARK: - My Teams manager

/// Multi-team memberships: the starred team is the upload/watch default; a second team is gated
/// behind the team subscription. Preserves star / initials-toggle / remove / add from the original.
struct MembershipsCard: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(EntitlementStore.self) private var entitlements

    @Binding var newTeamCode: String
    var onShowPaywall: () -> Void
    var onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("My Teams").captionLabel().foregroundStyle(Theme.turf)

            ForEach(settings.teamMemberships) { membership in
                membershipRow(membership)
            }

            HStack(spacing: 8) {
                TextField("Add team code", text: $newTeamCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.surfaceStroke, lineWidth: 1))
                Button("Add") { addMembership() }
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(Theme.turf)
                    .disabled(newTeamCode.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if !entitlements.entitledToTeam && !settings.teamMemberships.isEmpty {
                Button(action: onShowPaywall) {
                    Label("Multiple teams require Team features", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .themedCard()
    }

    private func membershipRow(_ membership: TeamMembership) -> some View {
        let isDefault = membership.code == settings.teamCode
        return HStack(spacing: 12) {
            Button {
                Haptics.selection()
                onSelect(membership.code)
            } label: {
                Image(systemName: isDefault ? "star.fill" : "star")
                    .foregroundStyle(isDefault ? Theme.sprint : Theme.bench)
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 1) {
                Text(membership.code).font(.body.monospaced().weight(isDefault ? .semibold : .regular))
                if let name = membership.name {
                    Text(name).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()

            // Minors-privacy: render this member as initials only (also enforced server-side).
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
            onShowPaywall()
            return
        }
        memberships.append(TeamMembership(code: code, name: nil, displayInitialsOnly: false))
        settings.teamMemberships = memberships
        newTeamCode = ""
        if settings.teamCode.isEmpty {
            settings.teamCode = code
        }
        environment.settingsChanged()
    }
}

// MARK: - Team features

/// Formation + chat, both team-subscription features; unentitled players see a single unlock CTA.
struct TeamFeaturesCard: View {
    @Environment(EntitlementStore.self) private var entitlements
    let teamCode: String
    var onShowPaywall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Team Features").captionLabel().foregroundStyle(Theme.signal)

            if entitlements.entitledToTeam {
                NavigationLink {
                    FormationView(teamCode: teamCode)
                } label: {
                    featureRow("Formation", "square.grid.3x3.middle.filled", Theme.pace)
                }
                .buttonStyle(.plain)
                NavigationLink {
                    TeamChatView()
                } label: {
                    featureRow("Match Chat", "bubble.left.and.bubble.right.fill", Theme.signal)
                }
                .buttonStyle(.plain)
            } else {
                Button(action: onShowPaywall) {
                    featureRow("Unlock formation, chat & live dashboard", "lock.fill", Theme.sprint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .themedCard()
    }

    private func featureRow(_ title: String, _ icon: String, _ tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 28)
            Text(title)
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
        }
    }
}
