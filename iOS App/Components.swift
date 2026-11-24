// Components.swift
// MatchTracker

import SwiftUI
import MatchTrackerKit

/// A number over its label.
struct StatTile: View {
    let title: String
    let value: String
    var systemImage: String?
    var tint: Color = Theme.turf

    var body: some View {
        VStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.footnote).foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            Text(value).statNumeral().lineLimit(1).minimumScaleFactor(0.6)
            Text(title).captionLabel().multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

/// A count and what it counts (e.g. "12 runs").
struct SummaryChip: View {
    let value: String
    let label: String
    var tint: Color = Theme.turf

    var body: some View {
        StatTile(title: label, value: value)
    }
}

/// Abbreviated position ("LM", "CF", "GK") derived from role + side.
struct PositionBadge: View {
    let role: PositionRole
    let side: PositionSide
    /// Legacy: confidence is never shown.
    var confidence: Double?

    var body: some View {
        Text(Self.abbreviation(role: role, side: side))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.secondaryLabel)
            .accessibilityLabel(Self.fullName(role: role, side: side))
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
        case .goalAgainstUs, .redCard: return Theme.loss
        case .assist: return Theme.goal
        case .yellowCard: return Theme.cardYellow
        default: return .secondary
        }
    }
}
