//
//  EventsView.swift
//  MatchTracker
//

import SwiftUI
import MatchTrackerKit

/// Page 3 of the live session: event logging. Players get the giant Flag button plus
/// goal/assist logging; referee mode swaps to cards and fouls; other sports get their own
/// vocabulary from the sport profile. Every log gives a semantic haptic and a brief flash so
/// the player knows it registered without looking closely.
struct EventsView: View {
    @Environment(WorkoutManager.self) private var workoutManager
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @State private var confirmation: Confirmation?

    private var refereeMode: Bool { WatchSettings.refereeMode }
    private var sport: SportProfile { WatchSettings.sportProfile }

    /// A single event confirmation: the label to flash plus the tint that colors its checkmark.
    private struct Confirmation: Equatable {
        let text: String
        let tint: Color
    }

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
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Text("\(workoutManager.score.us)")
                    .foregroundStyle(WatchTheme.turf)
                    .contentTransition(.numericText())
                Text("–")
                    .foregroundStyle(.secondary)
                Text("\(workoutManager.score.them)")
                    .foregroundStyle(WatchTheme.loss)
                    .contentTransition(.numericText())
            }
            .font(.system(size: 34, weight: .bold, design: .rounded))
            .monospacedDigit()
            .animation(.snappy, value: workoutManager.score.us)
            .animation(.snappy, value: workoutManager.score.them)

            Text("\(workoutManager.loggedEventCount) events")
                .watchCaptionLabel()
                .foregroundStyle(.secondary)
            if autoSubCount > 0 {
                Label("\(autoSubCount) auto", systemImage: "wand.and.stars")
                    .font(.caption2)
                    .foregroundStyle(WatchTheme.signal)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
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
            logEvent(.flag, label: "Flagged", tint: WatchTheme.signal)
        } label: {
            Label("Flag", systemImage: "flag.fill")
                .font(.title2.weight(.bold))
        }
        .buttonStyle(WatchTileButtonStyle(tint: WatchTheme.signal, minHeight: 64))

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
                eventButton("Goal Them", systemImage: "soccerball.inverse", kind: .goalAgainstUs)
            }
            HStack(spacing: 8) {
                eventButton("My Goal", systemImage: "star.fill", kind: .goalMine)
                eventButton("Assist", systemImage: "hand.thumbsup.fill", kind: .assist)
            }
        }
    }

    private var refereeButtons: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                eventButton("Yellow", systemImage: "rectangle.portrait.fill", kind: .yellowCard)
                eventButton("Red", systemImage: "rectangle.portrait.fill", kind: .redCard)
            }
            HStack(spacing: 8) {
                eventButton("Foul", systemImage: "exclamationmark.triangle", kind: .foul)
                goalUsButton
            }
            HStack(spacing: 8) {
                eventButton("Goal Them", systemImage: "soccerball.inverse", kind: .goalAgainstUs)
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
                    eventButton(kind.watchTitle, systemImage: kind.watchSymbol, kind: kind)
                }
            }
        }
    }

    @ViewBuilder
    private var goalUsButton: some View {
        let button = eventButton("Goal Us", systemImage: "soccerball", kind: .goalForUs)
        if #available(watchOS 11.0, *), WatchSettings.doubleTapAction == .goalUs {
            button.handGestureShortcut(.primaryAction)
        } else {
            button
        }
    }

    private func eventButton(_ title: String, systemImage: String, kind: MatchEventKind) -> some View {
        let tint = kind.watchTint
        return Button {
            logEvent(kind, label: title, tint: tint)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.caption2.weight(.semibold))
            }
        }
        .buttonStyle(WatchTileButtonStyle(tint: tint))
    }

    @ViewBuilder
    private var confirmationOverlay: some View {
        if let confirmation {
            ConfirmationFlash(text: confirmation.text, tint: confirmation.tint)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
        }
    }

    /// Log the event, fire its semantic haptic, and flash a tinted confirmation. Respects
    /// always-on: under reduced luminance the flash fades in plainly without the spring.
    private func logEvent(_ kind: MatchEventKind, label: String, tint: Color) {
        workoutManager.log(kind)
        WatchHaptics.forEvent(positive: kind.isPositiveMoment,
                              caution: kind.isCaution,
                              negative: kind.isNegativeMoment)
        let flash = Confirmation(text: label, tint: tint)
        withAnimation(isLuminanceReduced ? .easeIn(duration: 0.15)
                                         : .spring(response: 0.3, dampingFraction: 0.7)) {
            confirmation = flash
        }
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
        case .goalForUs: return WatchTheme.turf
        case .goalAgainstUs, .redCard: return WatchTheme.loss
        case .goalMine: return WatchTheme.sprint
        case .assist: return WatchTheme.pace
        case .yellowCard: return WatchTheme.cardYellow
        case .foul: return WatchTheme.sprint
        case .turnover: return WatchTheme.signal
        case .timeout: return WatchTheme.bench
        default: return WatchTheme.signal
        }
    }

    /// Positive moments earn a success haptic — our goals, my goals, assists.
    var isPositiveMoment: Bool {
        switch self {
        case .goalForUs, .goalMine, .assist: return true
        default: return false
        }
    }

    /// Cautions (cards, fouls) earn a notification buzz.
    var isCaution: Bool {
        switch self {
        case .yellowCard, .redCard, .foul: return true
        default: return false
        }
    }

    /// A goal conceded earns a distinct failure buzz.
    var isNegativeMoment: Bool { self == .goalAgainstUs }
}
