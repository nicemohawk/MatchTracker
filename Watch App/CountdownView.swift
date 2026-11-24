//
//  CountdownView.swift
//  MatchTracker
//

import Combine
import SwiftUI
import WatchKit

/// A 3-second countdown to kickoff. Purely a display: recording began on the Start tap, so even a
/// countdown the watch sleeps through costs nothing but the animation. Tap to skip it.
struct CountdownView: View {
    @Environment(WorkoutManager.self) private var workoutManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var remaining = 3

    private let tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.green.opacity(0.15).ignoresSafeArea()
            Text("\(remaining)")
                .font(.system(size: 96, weight: .bold, design: .rounded))
                .foregroundStyle(.green)
                .contentTransition(.numericText(countsDown: true))
                .transaction { $0.animation = .snappy }
        }
        .contentShape(Rectangle())
        .onTapGesture { workoutManager.skipCountdown() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Skips the countdown")
        .onAppear {
            WKInterfaceDevice.current().play(.start)
            refresh()
        }
        .onReceive(tick) { _ in refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
    }

    private func refresh() {
        let secondsLeft = workoutManager.countdownDeadline.timeIntervalSinceNow
        let display = max(1, Int(secondsLeft.rounded(.up)))
        if display != remaining {
            remaining = display
            WKInterfaceDevice.current().play(.click)
        }
        if secondsLeft <= 0 {
            workoutManager.kickoffIfCountdownElapsed(trigger: "countdown view")
        }
    }
}
