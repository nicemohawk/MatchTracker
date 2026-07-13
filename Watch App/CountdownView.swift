//
//  CountdownView.swift
//  MatchTracker
//

import SwiftUI
import WatchKit

/// A 3-second countdown before kickoff, then starts the workout session.
struct CountdownView: View {
    @Environment(WorkoutManager.self) private var workoutManager
    @State private var remaining = 3

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.green.opacity(0.15).ignoresSafeArea()
            Text("\(remaining)")
                .font(.system(size: 96, weight: .bold, design: .rounded))
                .foregroundStyle(.green)
                .contentTransition(.numericText(countsDown: true))
                .transaction { $0.animation = .snappy }
        }
        .onAppear { WKInterfaceDevice.current().play(.start) }
        .onReceive(timer) { _ in
            if remaining > 1 {
                remaining -= 1
                WKInterfaceDevice.current().play(.click)
            } else {
                timer.upstream.connect().cancel()
                Task { await workoutManager.startMatch(field: workoutManager.detectedField) }
            }
        }
    }
}
