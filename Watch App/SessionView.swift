//
//  SessionView.swift
//  MatchTracker
//

import SwiftUI

/// The live in-game experience: a vertically-paged tab view matching Apple's Workout app —
/// Controls, Metrics, Events.
struct SessionView: View {
    enum Page { case controls, metrics, events }

    @Environment(WorkoutManager.self) private var workoutManager
    @State private var selection: Page = .metrics

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
