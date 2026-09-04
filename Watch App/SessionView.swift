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
        TabView(selection: $selection) {
            ControlsView()
                .tag(Page.controls)
            MetricsView()
                .tag(Page.metrics)
            EventsView()
                .tag(Page.events)
        }
        .tabViewStyle(.verticalPage)
        .overlay(alignment: .top) { autoSubBanner }
        .animation(.snappy, value: workoutManager.autoSubBanner)
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

    /// Brief confirmation that an automatic substitution was detected.
    @ViewBuilder
    private var autoSubBanner: some View {
        if let message = workoutManager.autoSubBanner {
            Label(message, systemImage: "wand.and.stars")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.top, 4)
        }
    }
}
