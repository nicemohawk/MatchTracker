//
//  SessionView.swift
//  MatchTracker
//

import SwiftUI
import MatchTrackerKit

/// The live in-game experience: a vertically-paged tab view matching Apple's Workout app —
/// Controls, Metrics, Events.
struct SessionView: View {
    enum Page { case controls, metrics, events }

    @Environment(WorkoutManager.self) private var workoutManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: Page = .metrics

    /// When the session screen last stopped being frontmost, so a wrist-down can be told from a
    /// glance away. Nil while the screen is up.
    @State private var leftActiveAt: Date?

    /// How long away counts as "put the watch down" rather than "looked away for a second".
    private let restingPageDelay: TimeInterval = 10

    var body: some View {
        // In place of the pages rather than over them, so nothing they've put up can cover it.
        if let question = workoutManager.endQuestion {
            EndQuestionView(question: question)
        } else {
            pages
        }
    }

    private var pages: some View {
        TabView(selection: $selection) {
            ControlsView()
                .tag(Page.controls)
            MetricsView()
                .tag(Page.metrics)
            EventsView()
                .tag(Page.events)
        }
        .tabViewStyle(.verticalPage)
        .onChange(of: workoutManager.autoSubNoticed) { _, noticed in
            if noticed != nil { withAnimation(.snappy) { selection = .metrics } }
        }
        .onChange(of: scenePhase) { _, phase in
            phase == .active ? returnToRestingPage() : noteLeftActive()
        }
    }

    /// Snap back to Metrics when the wrist comes up after a real absence.
    ///
    /// Logging an event leaves you on the Events page, and without this that grid of buttons is
    /// what greets every raise for the rest of the match — the wrong thing to glance at mid-play,
    /// and live controls under a finger that's on its way up. Deliberately NOT done when the event
    /// is logged: goals cluster with assists (and fouls with cards), and a page transition right
    /// then would eat the follow-up tap.
    private func returnToRestingPage() {
        defer { leftActiveAt = nil }
        guard let leftActiveAt, selection != .metrics else { return }
        let away = Date().timeIntervalSince(leftActiveAt)
        guard away >= restingPageDelay else { return }
        MatchLog.info("session: back to metrics after \(Int(away))s away", category: "ui")
        withAnimation(.snappy) { selection = .metrics }
    }

    /// Start the away clock on the first step out of active — .inactive then .background must not
    /// restart it, or a wrist-down would never measure as long enough.
    private func noteLeftActive() {
        guard leftActiveAt == nil else { return }
        leftActiveAt = Date()
    }
}

/// Shown when the match looks over but was never ended. A forgotten match once ran for 32 hours;
/// ending from here also takes it back to when play stopped.
private struct EndQuestionView: View {
    let question: StillPlaying.Question

    @Environment(WorkoutManager.self) private var workoutManager
    @State private var acceptsTaps = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Button {
                    WatchHaptics.stop()
                    Task { await workoutManager.endMatch(answering: question) }
                } label: {
                    VStack(spacing: 0) {
                        Text("End Match")
                        if let endTime { Text("at \(endTime)").font(.footnote) }
                    }
                }
                .buttonStyle(WatchTileButtonStyle(tint: WatchTheme.loss, minHeight: 52))
                Button("Still Playing") {
                    WatchHaptics.click()
                    workoutManager.answerStillPlaying()
                }
                .buttonStyle(WatchTileButtonStyle(tint: WatchTheme.turf, minHeight: 48))
            }
            .font(.headline)
            .scenePadding(.horizontal)
        }
        // It arrives by itself, perhaps under a finger already on its way down.
        .allowsHitTesting(acceptsTaps)
        .task {
            try? await Task.sleep(for: .seconds(1))
            acceptsTaps = true
        }
    }

    private var title: String {
        switch question.reason {
        case .left: return "You've left the pitch"
        case .noPlay: return "No play since \(question.end.formatted(date: .omitted, time: .shortened))"
        case .longSession: return "Still playing?"
        }
    }

    /// Nil when that's now.
    private var endTime: String? {
        Date().timeIntervalSince(question.end) > 60 ? question.end.formatted(date: .omitted, time: .shortened) : nil
    }
}
