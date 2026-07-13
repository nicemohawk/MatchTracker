// Components.swift
// MatchTracker

import SwiftUI
import MatchTrackerKit

/// Compact labeled value used in header stat rows.
struct StatTile: View {
    let title: String
    let value: String
    var systemImage: String?

    var body: some View {
        VStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.caption).foregroundStyle(.secondary)
            }
            Text(value).font(.headline).monospacedDigit()
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Rounded summary chip (e.g. "12 runs").
struct SummaryChip: View {
    let value: String
    let label: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.bold()).monospacedDigit().foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Abbreviated position badge ("LM", "CF", "GK") derived from role + side.
struct PositionBadge: View {
    let role: PositionRole
    let side: PositionSide
    var confidence: Double?

    var body: some View {
        Text(Self.abbreviation(role: role, side: side))
            .font(.caption.bold())
            .foregroundStyle(.white)
            .frame(width: 34, height: 24)
            .background(role.tint, in: RoundedRectangle(cornerRadius: 6))
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
        case .goalkeeper: return .yellow
        case .defender: return .blue
        case .midfielder: return .green
        case .forward: return .red
        }
    }
}

extension RunIntensity {
    var color: Color {
        switch self {
        case .jog: return .green
        case .run: return .orange
        case .sprint: return .red
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
        }
    }

    var tint: Color {
        switch self {
        case .goalForUs, .goalMine: return .green
        case .goalAgainstUs: return .red
        case .assist: return .mint
        case .flag: return .orange
        default: return .secondary
        }
    }
}
