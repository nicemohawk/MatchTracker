//
//  EventsView.swift
//  MatchTracker
//

import SwiftUI
import MatchTrackerKit

/// Score and moments. The two halves of the scoreline are the buttons — the biggest targets the
/// screen can hold — and the detail ("who scored?") is asked afterwards, when there's a second to
/// answer it. Every log can be undone from its own confirmation.
struct EventsView: View {
    @Environment(WorkoutManager.self) private var workoutManager
    @State private var confirmation: Confirmation?
    @State private var scorerPrompt: MatchEvent?

    private var sport: SportProfile { WatchSettings.sportProfile }

    private struct Confirmation: Equatable {
        let eventID: UUID
        let text: String
        let tint: Color
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 8) {
                    // Leaves the top of the next row in view: there is more below.
                    HStack(spacing: 8) {
                        scoreTile("Us", value: workoutManager.score.us, kind: .goalForUs,
                                  tint: WatchTheme.turf, height: proxy.size.height * 0.62)
                        scoreTile("Them", value: workoutManager.score.them, kind: .goalAgainstUs,
                                  tint: WatchTheme.loss, height: proxy.size.height * 0.62)
                    }
                    if WatchSettings.refereeMode {
                        HStack(spacing: 8) {
                            eventTile(.yellowCard, title: "Yellow")
                            eventTile(.redCard, title: "Red")
                        }
                        eventTile(.foul, title: "Foul")
                    } else {
                        ForEach(secondaryKinds, id: \.self) { kind in
                            eventTile(kind, title: kind.watchTitle)
                        }
                    }
                    flagTile
                }
            }
        }
        .scenePadding(.horizontal)
        .overlay { confirmationOverlay }
        .sheet(item: $scorerPrompt) { goal in
            ScorerSheet { choice in
                switch choice {
                case .me: workoutManager.changeEvent(goal.id, to: .goalMine)
                case .myAssist: workoutManager.log(.assist)
                case .teammate: break
                }
            }
        }
    }

    /// Sports other than soccer bring their own vocabulary; goals, subs and flags are already here.
    private var secondaryKinds: [MatchEventKind] {
        guard sport.id != SportProfile.soccer.id else { return [] }
        return sport.eventVocabulary.filter {
            ![.matchStart, .matchEnd, .periodStart, .periodEnd, .subIn, .subOut, .flag,
              .goalForUs, .goalAgainstUs, .goalMine, .assist].contains($0)
        }
    }

    @ViewBuilder
    private func scoreTile(_ side: String, value: Int, kind: MatchEventKind, tint: Color, height: CGFloat) -> some View {
        let button = Button {
            log(kind, text: kind == .goalForUs ? "Goal!" : "They scored", tint: tint)
        } label: {
            VStack(spacing: 0) {
                Text("\(value)")
                    .font(.system(size: height * 0.55, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(side)
                    .font(.headline)
            }
        }
        .buttonStyle(WatchTileButtonStyle(tint: tint, minHeight: height))
        .accessibilityLabel(kind == .goalForUs ? "Goal Us" : "Goal Them")
        .accessibilityValue("\(value)")
        .accessibilityHint("Adds a goal")
        .animation(.snappy, value: value)

        if #available(watchOS 11.0, *), kind == .goalForUs, WatchSettings.doubleTapAction == .goalUs {
            button.handGestureShortcut(.primaryAction)
        } else {
            button
        }
    }

    @ViewBuilder
    private var flagTile: some View {
        let button = eventTile(.flag, title: "Flag")
        if #available(watchOS 11.0, *), WatchSettings.doubleTapAction == .flag {
            button.handGestureShortcut(.primaryAction)
        } else {
            button
        }
    }

    private func eventTile(_ kind: MatchEventKind, title: String) -> some View {
        Button {
            log(kind, text: kind == .flag ? "Moment flagged" : title, tint: kind.watchTint)
        } label: {
            Label(title, systemImage: kind.watchSymbol)
                .font(.headline)
        }
        .buttonStyle(WatchTileButtonStyle(tint: kind.watchTint, minHeight: 52))
    }

    @ViewBuilder
    private var confirmationOverlay: some View {
        if let confirmation {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(confirmation.tint)
                Text(confirmation.text)
                    .font(.title3.weight(.semibold))
                Button("Undo") {
                    workoutManager.removeEvent(confirmation.eventID)
                    WatchHaptics.click()
                    withAnimation(.easeOut) { self.confirmation = nil }
                }
                .buttonStyle(WatchTileButtonStyle(tint: .white, minHeight: 44))
            }
            .scenePadding(.horizontal)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black.opacity(0.9))
            .transition(.opacity)
        }
    }

    /// Log, buzz and confirm. A goal for us then asks who, once the confirmation has had its moment.
    private func log(_ kind: MatchEventKind, text: String, tint: Color) {
        let event = workoutManager.log(kind)
        WatchHaptics.forEvent(positive: kind.isPositiveMoment,
                              caution: kind.isCaution,
                              negative: kind.isNegativeMoment)
        let shown = Confirmation(eventID: event.id, text: text, tint: tint)
        withAnimation(.snappy) { confirmation = shown }
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard confirmation == shown else { return }
            withAnimation(.easeOut) { confirmation = nil }
            if kind == .goalForUs, !WatchSettings.refereeMode, workoutManager.events.contains(where: { $0.id == event.id }) {
                scorerPrompt = event
            }
        }
    }
}

/// "Who scored?" — three full-width answers. Dismissing means a teammate.
private struct ScorerSheet: View {
    enum Choice { case me, myAssist, teammate }

    let onChoose: (Choice) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                choice("I scored", systemImage: "star.fill", tint: WatchTheme.sprint, .me)
                choice("My assist", systemImage: "hand.thumbsup.fill", tint: WatchTheme.pace, .myAssist)
                choice("Teammate", systemImage: "person.2.fill", tint: WatchTheme.bench, .teammate)
            }
            .scenePadding(.horizontal)
        }
        .navigationTitle("Who scored?")
        .task {
            // Left unanswered — play restarted — it gets out of the way by itself.
            try? await Task.sleep(for: .seconds(12))
            dismiss()
        }
    }

    private func choice(_ title: String, systemImage: String, tint: Color, _ choice: Choice) -> some View {
        Button {
            WatchHaptics.click()
            onChoose(choice)
            dismiss()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.headline)
        }
        .buttonStyle(WatchTileButtonStyle(tint: tint, minHeight: 52))
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
        case .flag: return "flag.fill"
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
