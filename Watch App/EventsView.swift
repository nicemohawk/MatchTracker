//
//  EventsView.swift
//  MatchTracker
//

import SwiftUI
import MatchTrackerKit

/// Page 3 of the live session: event logging. Players get the giant Flag button plus
/// goal/assist logging; referee mode swaps to cards and fouls; other sports get their own
/// vocabulary from the sport profile. Every log gives a success haptic and a brief overlay.
struct EventsView: View {
    @Environment(WorkoutManager.self) private var workoutManager
    @State private var confirmation: String?

    private var refereeMode: Bool { WatchSettings.refereeMode }
    private var sport: SportProfile { WatchSettings.sportProfile }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                scoreHeader
                flagButton
                if refereeMode {
                    refereeButtons
                } else if sport.id == SportProfile.soccer.id {
                    soccerButtons
                } else {
                    sportButtons
                }
            }
            .padding(.horizontal, 4)
        }
        .overlay { confirmationOverlay }
    }

    private var scoreHeader: some View {
        VStack(spacing: 2) {
            Text("\(workoutManager.score.us)–\(workoutManager.score.them)")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("\(workoutManager.loggedEventCount) events")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if autoSubCount > 0 {
                Label("\(autoSubCount) auto", systemImage: "wand.and.stars")
                    .font(.caption2)
                    .foregroundStyle(.teal)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Automatic substitutions detected so far this match.
    private var autoSubCount: Int {
        workoutManager.events.filter {
            $0.source == .automatic && ($0.kind == .subIn || $0.kind == .subOut)
        }.count
    }

    @ViewBuilder
    private var flagButton: some View {
        let button = Button {
            logEvent(.flag, label: "Flagged")
        } label: {
            Label("Flag", systemImage: "flag.fill")
                .font(.title2.weight(.bold))
                .frame(maxWidth: .infinity, minHeight: 64)
        }
        .tint(.purple)

        // Hands-free double-tap triggers the user's chosen action; Flag is the default.
        if #available(watchOS 11.0, *), WatchSettings.doubleTapAction == .flag {
            button.handGestureShortcut(.primaryAction)
        } else {
            button
        }
    }

    private var soccerButtons: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                goalUsButton
                eventButton("Goal Them", systemImage: "soccerball.inverse", tint: .red, kind: .goalAgainstUs)
            }
            HStack(spacing: 8) {
                eventButton("My Goal", systemImage: "star.fill", tint: .yellow, kind: .goalMine)
                eventButton("Assist", systemImage: "hand.thumbsup.fill", tint: .blue, kind: .assist)
            }
        }
    }

    private var refereeButtons: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                eventButton("Yellow", systemImage: "rectangle.portrait.fill", tint: .yellow, kind: .yellowCard)
                eventButton("Red", systemImage: "rectangle.portrait.fill", tint: .red, kind: .redCard)
            }
            HStack(spacing: 8) {
                eventButton("Foul", systemImage: "exclamationmark.triangle", tint: .orange, kind: .foul)
                goalUsButton
            }
            HStack(spacing: 8) {
                eventButton("Goal Them", systemImage: "soccerball.inverse", tint: .red, kind: .goalAgainstUs)
            }
        }
    }

    /// Generic grid for non-soccer sports, driven by the profile's event vocabulary.
    private var sportButtons: some View {
        let kinds = sport.eventVocabulary.filter { kind in
            switch kind {
            case .matchStart, .matchEnd, .periodStart, .periodEnd, .subIn, .subOut, .flag:
                return false
            default:
                return true
            }
        }
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(kinds, id: \.self) { kind in
                if kind == .goalForUs {
                    goalUsButton
                } else {
                    eventButton(kind.watchTitle, systemImage: kind.watchSymbol,
                                tint: kind.watchTint, kind: kind)
                }
            }
        }
    }

    @ViewBuilder
    private var goalUsButton: some View {
        let button = eventButton("Goal Us", systemImage: "soccerball", tint: .green, kind: .goalForUs)
        if #available(watchOS 11.0, *), WatchSettings.doubleTapAction == .goalUs {
            button.handGestureShortcut(.primaryAction)
        } else {
            button
        }
    }

    private func eventButton(_ title: String, systemImage: String, tint: Color, kind: MatchEventKind) -> some View {
        Button {
            logEvent(kind, label: title)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
        }
        .tint(tint)
    }

    @ViewBuilder
    private var confirmationOverlay: some View {
        if let confirmation {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.green)
                Text(confirmation)
                    .font(.headline)
            }
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .transition(.scale.combined(with: .opacity))
        }
    }

    private func logEvent(_ kind: MatchEventKind, label: String) {
        workoutManager.log(kind)
        withAnimation(.snappy) { confirmation = label }
        Task {
            try? await Task.sleep(for: .seconds(1))
            withAnimation(.easeOut) { confirmation = nil }
        }
    }
}

/// Watch-side presentation for event kinds outside the fixed soccer layout.
extension MatchEventKind {
    var watchTitle: String {
        switch self {
        case .goalForUs: return "Goal Us"
        case .goalAgainstUs: return "Goal Them"
        case .goalMine: return "My Goal"
        case .assist: return "Assist"
        case .yellowCard: return "Yellow"
        case .redCard: return "Red"
        case .foul: return "Foul"
        case .turnover: return "Turnover"
        case .timeout: return "Timeout"
        default: return rawValue.capitalized
        }
    }

    var watchSymbol: String {
        switch self {
        case .goalForUs: return "soccerball"
        case .goalAgainstUs: return "soccerball.inverse"
        case .goalMine: return "star.fill"
        case .assist: return "hand.thumbsup.fill"
        case .yellowCard, .redCard: return "rectangle.portrait.fill"
        case .foul: return "exclamationmark.triangle"
        case .turnover: return "arrow.triangle.2.circlepath"
        case .timeout: return "pause.circle"
        default: return "circle"
        }
    }

    var watchTint: Color {
        switch self {
        case .goalForUs: return .green
        case .goalAgainstUs, .redCard: return .red
        case .goalMine: return .yellow
        case .assist: return .blue
        case .yellowCard: return .yellow
        case .foul: return .orange
        case .turnover: return .teal
        case .timeout: return .gray
        default: return .purple
        }
    }
}
