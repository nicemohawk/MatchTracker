//
//  CountdownView.swift
//  MatchTracker
//

import SwiftUI
import WatchKit

/// A 3-second countdown before kickoff, then starts the workout session.
///
/// The numeral is derived from `WorkoutManager.countdownDeadline` rather than decremented per
/// tick, and kickoff is the manager's job: a dropped tick (the watch suspends the app as soon as
/// the wrist drops) can no longer strand the match on "1". Reactivating the app re-checks the
/// deadline immediately, so a countdown that ran out while the screen was off starts on wake.
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
            Task { await workoutManager.kickoffIfCountdownElapsed(trigger: "countdown view") }
        }
    }
}
