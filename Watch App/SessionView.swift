//
//  SessionView.swift
//  MatchTracker
//

import SwiftUI

/// The live in-game experience: a vertically-paged tab view matching Apple's Workout app —
/// Controls, Metrics, Events.
struct SessionView: View {
    enum Page { case controls, metrics, events }

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
    }
}
