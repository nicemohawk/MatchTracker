// Components.swift
// MatchTracker

import SwiftUI
import MatchTrackerKit

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
