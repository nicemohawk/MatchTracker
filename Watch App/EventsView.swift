//
//  EventsView.swift
//  MatchTracker
//

import SwiftUI
import MatchTrackerKit

/// Score and moments. The two halves of the scoreline are the buttons — the biggest targets the
/// screen can hold. The new score comes straight back, with the detail (who scored?) if there's a
/// second to give it. Every log can be undone from its own confirmation, and the last goal at any time.
struct EventsView: View {
    @Environment(WorkoutManager.self) private var workoutManager
    @State private var confirmation: Confirmation?
    @State private var confirmingTakeBack = false

    private var sport: SportProfile { WatchSettings.sportProfile }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 8) {
                    // Leaves the top of the next row in view: there is more below.
                    ScoreTiles(height: proxy.size.height * 0.62, confirmation: $confirmation)
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
                    MomentTile(confirmation: $confirmation)
                    if let goal = workoutManager.lastGoal { takeBackTile(goal) }
                }
            }
        }
        .scenePadding(.horizontal)
        .confirmationOverlay($confirmation)
    }

    /// Sports other than soccer bring their own vocabulary; goals, subs and flags are already here.
    private var secondaryKinds: [MatchEventKind] {
        guard sport.id != SportProfile.soccer.id else { return [] }
        return sport.eventVocabulary.filter {
            ![.matchStart, .matchEnd, .periodStart, .periodEnd, .subIn, .subOut, .flag,
              .goalForUs, .goalAgainstUs, .goalMine, .assist].contains($0)
        }
    }

    private func takeBackTile(_ goal: MatchEvent) -> some View {
        Button {
            WatchHaptics.click()
            confirmingTakeBack = true
        } label: {
            Text("Take Back Last Goal")
                .font(.headline)
                .multilineTextAlignment(.center)
        }
        .buttonStyle(WatchTileButtonStyle(tint: WatchTheme.bench, minHeight: 52))
        .confirmationDialog("Take back \(whose(goal)) last goal?",
                            isPresented: $confirmingTakeBack, titleVisibility: .visible) {
            Button("Take Back", role: .destructive) {
                WatchHaptics.click()
                workoutManager.removeLastGoal()
            }
            Button("Keep It", role: .cancel) {}
        }
    }

    private func whose(_ goal: MatchEvent) -> String {
        goal.kind == .goalAgainstUs ? "their" : workoutManager.keepsScore ? "our" : "your"
    }

    private func eventTile(_ kind: MatchEventKind, title: String) -> some View {
        Button {
            confirmation = .logging(kind, in: workoutManager, text: title)
        } label: {
            Label(title, systemImage: kind.watchSymbol)
                .font(.headline)
        }
        .buttonStyle(WatchTileButtonStyle(tint: kind.watchTint, minHeight: 52))
    }
}

struct MomentTile: View {
    @Binding var confirmation: Confirmation?
    @Environment(WorkoutManager.self) private var workoutManager

    var body: some View {
        let button = Button {
            confirmation = .logging(.flag, in: workoutManager, text: "Moment marked")
        } label: {
            ViewThatFits(in: .horizontal) {
                Label("Mark Moment", systemImage: MatchEventKind.flag.watchSymbol)
                Label("Moment", systemImage: MatchEventKind.flag.watchSymbol)
            }
            .font(.headline)
        }
        .buttonStyle(WatchTileButtonStyle(tint: MatchEventKind.flag.watchTint, minHeight: 52))
        .accessibilityLabel("Mark Moment")

        if #available(watchOS 11.0, *), WatchSettings.doubleTapAction == .flag {
            button.handGestureShortcut(.primaryAction)
        } else {
            button
        }
    }
}

/// What was just logged, and how long it stays up to be undone.
struct Confirmation: Equatable {
    let eventID: UUID
    let text: String
    let tint: Color
    /// Their goal: the score itself is the confirmation.
    var isScore = false
    var seconds: TimeInterval { isScore ? 4 : 2 }

    /// Log and buzz, then confirm for a moment.
    static func logging(_ kind: MatchEventKind, in workoutManager: WorkoutManager, text: String,
                        tint: Color? = nil) -> Confirmation {
        let event = workoutManager.log(kind)
        WatchHaptics.forEvent(kind)
        return Confirmation(eventID: event.id, text: text, tint: tint ?? kind.watchTint)
    }
}

extension View {
    /// Covers the page for a moment with what was just logged.
    func confirmationOverlay(_ confirmation: Binding<Confirmation?>) -> some View {
        modifier(ConfirmationOverlay(confirmation: confirmation))
    }
}

private struct ConfirmationOverlay: ViewModifier {
    @Binding var confirmation: Confirmation?
    @Environment(WorkoutManager.self) private var workoutManager

    func body(content: Content) -> some View {
        content
            .overlay { overlay }
            .animation(.snappy, value: confirmation)
            .task(id: confirmation) {
                guard let confirmation else { return }
                try? await Task.sleep(for: .seconds(confirmation.seconds))
                if !Task.isCancelled { self.confirmation = nil }
            }
    }

    @ViewBuilder
    private var overlay: some View {
        if let confirmation {
            VStack(spacing: 10) {
                if confirmation.isScore {
                    KitNumber(confirmation.text, size: 104)
                        .foregroundStyle(confirmation.tint)
                        .accessibilityLabel("Score, us \(workoutManager.score.us), them \(workoutManager.score.them)")
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(confirmation.tint)
                    Text(confirmation.text)
                        .font(.title3.weight(.semibold))
                }
                Button("Undo") {
                    workoutManager.removeEvent(confirmation.eventID)
                    WatchHaptics.click()
                    self.confirmation = nil
                }
                .buttonStyle(WatchTileButtonStyle(tint: .white, minHeight: 44))
            }
            .scenePadding(.horizontal)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .transition(.opacity)
        }
    }
}

/// The two halves of the scoreline, each a button that adds a goal to it. Ours asks who scored;
/// theirs just shows the new score. With nobody counting, the wearer's own goals and assists.
struct ScoreTiles: View {
    let height: CGFloat
    @Binding var confirmation: Confirmation?

    @Environment(WorkoutManager.self) private var workoutManager
    @State private var goalPrompt: GoalPrompt?

    private struct GoalPrompt: Identifiable {
        let goal: MatchEvent
        let score: String
        var id: UUID { goal.id }
    }

    private var scoreText: String { "\(workoutManager.score.us)–\(workoutManager.score.them)" }

    var body: some View {
        HStack(spacing: 8) {
            if workoutManager.keepsScore { scoreTiles } else { ownTiles }
        }
        .sheet(item: $goalPrompt) { prompt in
            GoalSheet(score: prompt.score) { choice in
                switch choice {
                case .me: workoutManager.changeEvent(prompt.goal.id, to: .goalMine)
                case .myAssist: workoutManager.log(.assist)
                case .teammate: break
                case .undo: workoutManager.removeEvent(prompt.goal.id)
                }
            }
        }
    }

    private var scoreTiles: some View {
        Group {
            scoreTile("Us", value: workoutManager.score.us, kind: .goalForUs, tint: WatchTheme.turf)
            scoreTile("Them", value: workoutManager.score.them, kind: .goalAgainstUs, tint: WatchTheme.loss)
        }
    }

    @ViewBuilder
    private var ownTiles: some View {
        let scored = ownTile("I scored", kind: .goalMine, systemImage: "soccerball")
        if #available(watchOS 11.0, *), WatchSettings.doubleTapAction == .goalUs {
            scored.handGestureShortcut(.primaryAction)
        } else {
            scored
        }
        ownTile("My assist", kind: .assist, systemImage: MatchEventKind.assist.watchSymbol)
    }

    private func ownTile(_ title: String, kind: MatchEventKind, systemImage: String) -> some View {
        Button {
            confirmation = .logging(kind, in: workoutManager, text: title, tint: WatchTheme.turf)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: height * 0.34, weight: .semibold))
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .buttonStyle(WatchTileButtonStyle(tint: WatchTheme.turf, minHeight: height))
    }

    @ViewBuilder
    private func scoreTile(_ side: String, value: Int, kind: MatchEventKind, tint: Color) -> some View {
        let button = Button {
            logGoal(kind, tint: tint)
        } label: {
            VStack(spacing: 0) {
                Text("\(value)")
                    .font(.kit(height * 0.56))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
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

    private func logGoal(_ kind: MatchEventKind, tint: Color) {
        let event = workoutManager.log(kind)
        WatchHaptics.forEvent(kind)
        if kind == .goalForUs, !WatchSettings.refereeMode {
            goalPrompt = GoalPrompt(goal: event, score: scoreText)
        } else {
            confirmation = Confirmation(eventID: event.id, text: scoreText, tint: tint, isScore: true)
        }
    }
}

/// The new score, and who scored it. Dismissing means a teammate.
private struct GoalSheet: View {
    enum Choice { case me, myAssist, teammate, undo }

    let score: String
    let onChoose: (Choice) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                KitNumber(score, size: 68)
                    .foregroundStyle(WatchTheme.ivory)
                    .accessibilityAddTraits(.isHeader)
                choice("I scored", systemImage: "soccerball", tint: WatchTheme.turf, .me)
                choice("My assist", systemImage: "hand.thumbsup.fill", tint: WatchTheme.turf, .myAssist)
                choice("Teammate", systemImage: "person.2.fill", tint: WatchTheme.bench, .teammate)
                choice("Undo", systemImage: "arrow.uturn.backward", tint: WatchTheme.loss, .undo)
            }
            .scenePadding(.horizontal)
        }
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
        .buttonStyle(WatchTileButtonStyle(tint: tint, minHeight: 48))
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
