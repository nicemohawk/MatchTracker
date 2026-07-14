// TeamRosterViews.swift
// MatchTracker
//
// The Team-tab leaderboard: a Strava-club-style ranked list that replaces the old cramped
// 7-column roster table. One hero metric per row, a chip picker to re-rank, medal treatment for
// the podium, and an inline expandable detail carrying the full stat set the table used to show.

import SwiftUI
import MatchTrackerKit

// MARK: - Metric

/// The leaderboard's selectable hero metric. Each case knows its accent, how to pull a sortable
/// value from a `TeamStats.Player`, and how to render that value as a big monospaced numeral.
enum TeamMetric: String, CaseIterable, Identifiable {
    case workrate, distance, goals, assists, sprints, minutes

    var id: String { rawValue }

    var label: String {
        switch self {
        case .workrate: return "Workrate"
        case .distance: return "Distance"
        case .goals: return "Goals"
        case .assists: return "Assists"
        case .sprints: return "Sprints"
        case .minutes: return "Minutes"
        }
    }

    var icon: String {
        switch self {
        case .workrate: return "bolt.fill"
        case .distance: return "figure.run"
        case .goals: return "soccerball"
        case .assists: return "hand.thumbsup.fill"
        case .sprints: return "hare.fill"
        case .minutes: return "clock.fill"
        }
    }

    /// Semantic tint, reusing the app's established mapping (turf = effort, pace = distance,
    /// sprint = sprints/amber, goal = green).
    var tint: Color {
        switch self {
        case .workrate: return Theme.turf
        case .distance: return Theme.pace
        case .goals: return Theme.goal
        case .assists: return Theme.signal
        case .sprints: return Theme.sprint
        case .minutes: return Theme.bench
        }
    }

    /// Sortable numeric value; optional stats collapse to 0 so they still rank.
    func value(_ player: TeamStats.Player) -> Double {
        switch self {
        case .workrate: return player.averageWorkrateScore
        case .distance: return player.totalDistanceMeters
        case .goals: return Double(player.goals)
        case .assists: return Double(player.assists)
        case .sprints: return Double(player.sprints ?? 0)
        case .minutes: return player.minutesPlayed ?? 0
        }
    }

    /// The big right-aligned hero numeral (unitless — the unit renders beside it).
    func heroText(_ player: TeamStats.Player) -> String {
        switch self {
        case .workrate: return "\(Int(player.averageWorkrateScore.rounded()))"
        case .distance: return String(format: "%.1f", player.totalDistanceMeters / 1000)
        case .goals: return "\(player.goals)"
        case .assists: return "\(player.assists)"
        case .sprints: return player.sprints.map { "\($0)" } ?? "—"
        case .minutes: return player.minutesPlayed.map { "\(Int($0.rounded()))" } ?? "—"
        }
    }

    /// Small unit caption under the hero numeral, if any.
    var unit: String? {
        switch self {
        case .workrate: return "score"
        case .distance: return "km"
        case .goals: return "goals"
        case .assists: return "assists"
        case .sprints: return "sprints"
        case .minutes: return "min"
        }
    }
}

// MARK: - Metric picker

/// Capsule-chip segmented picker matching MatchDetailView's chip idiom: the selected chip fills
/// with its metric tint, the rest stay quiet on the elevated surface.
struct MetricPicker: View {
    @Binding var selection: TeamMetric
    var onSelect: (TeamMetric) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TeamMetric.allCases) { metric in
                    chip(metric)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    private func chip(_ metric: TeamMetric) -> some View {
        let isSelected = metric == selection
        return Button {
            guard metric != selection else { return }
            Haptics.selection()
            onSelect(metric)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: metric.icon).font(.caption2.weight(.bold))
                Text(metric.label).font(.system(.subheadline, design: .rounded).weight(.semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(isSelected ? metric.tint : Color.secondary)
            .background(
                Capsule().fill(isSelected ? Theme.chipFill(metric.tint) : Theme.surfaceElevated)
            )
            .overlay(
                Capsule().strokeBorder(
                    isSelected ? Theme.chipStroke(metric.tint) : Theme.surfaceStroke,
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Avatar

/// Deterministic initials avatar. The tint is a stable hash of the name into the app's accent
/// set, so a given teammate keeps the same color across launches.
enum RosterAvatar {
    static let palette: [Color] = [Theme.turf, Theme.signal, Theme.pace, Theme.sprint, Theme.heart]

    static func tint(for name: String) -> Color {
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFFFF }
        return palette[abs(hash) % palette.count]
    }

    static func initials(from name: String) -> String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "." }).filter { !$0.isEmpty }
        if parts.count >= 2 {
            return (parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        if let first = parts.first {
            return String(first.prefix(2)).uppercased()
        }
        return "?"
    }
}

struct PlayerAvatar: View {
    let name: String
    var size: CGFloat = 40

    var body: some View {
        let tint = RosterAvatar.tint(for: name)
        Text(RosterAvatar.initials(from: name))
            .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(Circle().fill(Theme.tintWash(tint, dark: 0.22, light: 0.14)))
            .overlay(Circle().strokeBorder(Theme.chipStroke(tint), lineWidth: 1))
    }
}

// MARK: - Rank medal

/// Podium treatment: gold/silver/bronze approximated within the token set (sprint amber, neutral
/// bench, dimmed sprint). Ranks 4+ get a quiet numeral.
private struct RankBadge: View {
    let rank: Int

    var body: some View {
        Group {
            if let tint = medalTint {
                Text("\(rank)")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.tintWash(tint, dark: 0.25, light: 0.16)))
                    .overlay(Circle().strokeBorder(tint.opacity(0.7), lineWidth: 1.5))
            } else {
                Text("\(rank)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
            }
        }
    }

    private var medalTint: Color? {
        switch rank {
        case 1: return Theme.sprint                 // gold
        case 2: return Theme.bench                  // silver
        case 3: return Theme.sprint.opacity(0.55)   // bronze (dimmed amber)
        default: return nil
        }
    }
}

// MARK: - Leaderboard row

/// One ranked teammate. Tapping toggles an inline expansion (spring) revealing the full stat set.
struct LeaderboardRow: View {
    let player: TeamStats.Player
    let rank: Int
    let metric: TeamMetric
    let isYou: Bool
    let isExpanded: Bool
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                header
                if isExpanded {
                    PlayerStatGrid(player: player, highlighted: metric)
                        .padding(.top, 14)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity
                        ))
                }
            }
            .padding(14)
            .background(rowBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isYou ? Theme.chipStroke(Theme.turf) : Theme.surfaceStroke, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack(spacing: 12) {
            RankBadge(rank: rank)
            PlayerAvatar(name: player.name)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(player.name)
                        .font(.system(.body, design: .rounded).weight(isYou ? .bold : .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if isYou {
                        Text("YOU")
                            .font(.system(size: 9, weight: .heavy, design: .rounded))
                            .tracking(0.5)
                            .foregroundStyle(Theme.turf)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.chipFill(Theme.turf)))
                    }
                }
                Text("\(player.matchesPlayed) \(player.matchesPlayed == 1 ? "match" : "matches")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            heroValue
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
        }
    }

    private var heroValue: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(metric.heroText(player))
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(metric.tint)
                .contentTransition(.numericText())
            if let unit = metric.unit {
                Text(unit)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 52, alignment: .trailing)
    }

    private var rowBackground: some View {
        ZStack {
            Theme.surface
            if isYou {
                Theme.tintWash(Theme.turf, dark: 0.10, light: 0.06)
            }
        }
    }
}

// MARK: - Expanded stat set

/// The full stat set the old table row carried, as labeled mini-stats. The currently ranked
/// metric is tinted so the expansion ties back to the leaderboard.
struct PlayerStatGrid: View {
    let player: TeamStats.Player
    let highlighted: TeamMetric

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(spacing: 12) {
            Divider().overlay(Theme.surfaceStroke)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                stat("Matches", "\(player.matchesPlayed)", Theme.bench, metric: nil)
                stat("Minutes", player.minutesPlayed.map { "\(Int($0.rounded()))" } ?? "—", Theme.bench, metric: .minutes)
                stat("Distance", String(format: "%.1f km", player.totalDistanceMeters / 1000), Theme.pace, metric: .distance)
                stat("Workrate", "\(Int(player.averageWorkrateScore.rounded()))", Theme.turf, metric: .workrate)
                stat("Sprints", player.sprints.map { "\($0)" } ?? "—", Theme.sprint, metric: .sprints)
                stat("Goals", "\(player.goals)", Theme.goal, metric: .goals)
                stat("Assists", "\(player.assists)", Theme.signal, metric: .assists)
            }
        }
    }

    private func stat(_ label: String, _ value: String, _ tint: Color, metric: TeamMetric?) -> some View {
        let isHot = metric == highlighted
        return VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isHot ? tint : .primary)
            Text(label).captionLabel()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Skeleton loading

/// Redacted placeholder rows shown while the roster loads — a leaderboard-shaped shimmer instead
/// of a bare spinner.
struct SkeletonLeaderboard: View {
    var rows = 5

    var body: some View {
        VStack(spacing: 10) {
            ForEach(0..<rows, id: \.self) { index in
                HStack(spacing: 12) {
                    Circle().fill(Theme.surfaceElevated).frame(width: 26, height: 26)
                    Circle().fill(Theme.surfaceElevated).frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceElevated)
                            .frame(width: 120 - CGFloat(index * 12), height: 13)
                        RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceElevated)
                            .frame(width: 60, height: 10)
                    }
                    Spacer()
                    RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceElevated)
                        .frame(width: 40, height: 22)
                }
                .padding(14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Theme.surfaceStroke, lineWidth: 1)
                )
            }
        }
        .redacted(reason: .placeholder)
        .shimmering()
    }
}

// MARK: - Shimmer

/// A lightweight left-to-right sheen for redacted placeholders.
private struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geometry in
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.06), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: geometry.size.width * 1.5)
                    .offset(x: phase * geometry.size.width * 1.5)
                }
                .allowsHitTesting(false)
            )
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

private extension View {
    func shimmering() -> some View { modifier(Shimmer()) }
}
