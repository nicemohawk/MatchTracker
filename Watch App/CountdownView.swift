//
//  CountdownView.swift
//  MatchTracker
//

import Combine
import MatchTrackerKit
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
        TimelineView(.animation) { context in
            let left = workoutManager.countdownDeadline.timeIntervalSince(context.date)
            ZStack {
                Circle().stroke(WatchTheme.turf.opacity(0.22), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: max(0, min(1, left / 3)))
                    .stroke(WatchTheme.turf, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                KitNumber("\(remaining)", size: 120)
                    .foregroundStyle(WatchTheme.ivory)
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
