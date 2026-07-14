// Components.swift
// MatchTracker

import SwiftUI
import MatchTrackerKit

/// Shared metric chip: big rounded numeral over an uppercase label, on a tinted metric tile.
/// Used in header stat rows across the app.
struct StatTile: View {
    let title: String
    let value: String
    var systemImage: String?
    var tint: Color = Theme.turf

    var body: some View {
        VStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).font(.caption).foregroundStyle(tint)
            }
            Text(value).statNumeral().foregroundStyle(.primary)
            Text(title).captionLabel()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .metricTile(tint: tint)
    }
}

/// Rounded summary chip (e.g. "12 runs").
struct SummaryChip: View {
    let value: String
    let label: String
    var tint: Color = Theme.turf

    var body: some View {
        VStack(spacing: 3) {
            Text(value).statNumeral().foregroundStyle(tint).glow(tint, radius: 6)
            Text(label).captionLabel()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .metricTile(tint: tint)
    }
}

/// Abbreviated position badge ("LM", "CF", "GK") derived from role + side.
struct PositionBadge: View {
    let role: PositionRole
    let side: PositionSide
    var confidence: Double?

    var body: some View {
        Text(Self.abbreviation(role: role, side: side))
            .font(.system(.caption, design: .rounded).bold())
            .foregroundStyle(.black)
            .frame(width: 36, height: 26)
            .background(role.tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .glow(role.tint, radius: 5)
            .opacity(confidenceOpacity)
    }

    private var confidenceOpacity: Double {
        guard let confidence else { return 1 }
        return 0.45 + 0.55 * min(1, max(0, confidence))
    }

    static func abbreviation(role: PositionRole, side: PositionSide) -> String {
        if role == .goalkeeper { return "GK" }
        let sideLetter: String
        switch side {
        case .left: sideLetter = "L"
        case .center: sideLetter = "C"
        case .right: sideLetter = "R"
        }
        let roleLetter: String
        switch role {
        case .defender: roleLetter = "B"
        case .midfielder: roleLetter = "M"
        case .forward: roleLetter = side == .center ? "F" : "W"
        case .goalkeeper: roleLetter = "K"
        }
        return sideLetter + roleLetter
    }

    static func fullName(role: PositionRole, side: PositionSide) -> String {
        if role == .goalkeeper { return "Goalkeeper" }
        let sideName: String
        switch side {
        case .left: sideName = "Left"
        case .center: sideName = "Central"
        case .right: sideName = "Right"
        }
        let roleName: String
        switch role {
        case .defender: roleName = "Defender"
        case .midfielder: roleName = "Midfielder"
        case .forward: roleName = "Forward"
        case .goalkeeper: roleName = "Goalkeeper"
        }
        return "\(sideName) \(roleName)"
    }
}

extension PositionRole {
    var tint: Color {
        switch self {
        case .goalkeeper: return Theme.bench
        case .defender: return Theme.pace
        case .midfielder: return Theme.turf
        case .forward: return Theme.sprint
        }
    }
}

extension RunIntensity {
    var color: Color {
        switch self {
        case .jog: return Theme.turf
        case .run: return Theme.sprint
        case .sprint: return Theme.heart
        }
    }
    var label: String { rawValue.capitalized }
}

extension MatchEventKind {
    var systemImage: String {
        switch self {
        case .matchStart, .periodStart: return "play.circle"
        case .matchEnd, .periodEnd: return "stop.circle"
        case .subIn: return "arrow.down.circle"
        case .subOut: return "arrow.up.circle"
        case .goalForUs: return "soccerball"
        case .goalAgainstUs: return "soccerball.inverse"
        case .goalMine: return "star.circle.fill"
        case .assist: return "hands.and.sparkles"
        case .flag: return "flag.fill"
        case .yellowCard, .redCard: return "rectangle.portrait.fill"
        case .foul: return "exclamationmark.triangle"
        case .turnover: return "arrow.triangle.2.circlepath"
        case .timeout: return "pause.circle"
        }
    }

    var title: String {
        switch self {
        case .matchStart: return "Match Start"
        case .matchEnd: return "Match End"
        case .periodStart: return "Period Start"
        case .periodEnd: return "Period End"
        case .subIn: return "Sub In"
        case .subOut: return "Sub Out"
        case .goalForUs: return "Goal For Us"
        case .goalAgainstUs: return "Goal Against"
        case .goalMine: return "My Goal"
        case .assist: return "Assist"
        case .flag: return "Flag"
        case .yellowCard: return "Yellow Card"
        case .redCard: return "Red Card"
        case .foul: return "Foul"
        case .turnover: return "Turnover"
        case .timeout: return "Timeout"
        }
    }

    var tint: Color {
        switch self {
        case .goalForUs, .goalMine: return Theme.goal
        case .goalAgainstUs: return Theme.heart
        case .assist: return Theme.signal
        case .flag: return Theme.sprint
        case .yellowCard: return Theme.bench
        case .redCard: return Theme.heart
        default: return .secondary
        }
    }
}
