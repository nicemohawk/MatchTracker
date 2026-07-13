//
//  MatchTrackerWatchApp.swift
//  MatchTracker
//

import SwiftUI

@main
struct MatchTrackerWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    @State private var workoutManager = WorkoutManager.shared
    @State private var connectivity = ConnectivityManager.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(workoutManager)
                .environment(connectivity)
                .task {
                    connectivity.activate()
                    await workoutManager.requestAuthorization()
                    await workoutManager.recoverActiveWorkoutSession()
                }
        }
    }
}

/// Handles crash recovery of an interrupted workout, per Apple's recommended flow.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func handleActiveWorkoutRecovery() {
        Task { await WorkoutManager.shared.recoverActiveWorkoutSession() }
    }
}

/// Switches between the start screen, countdown, live session and summary.
struct RootView: View {
    @Environment(WorkoutManager.self) private var workoutManager

    var body: some View {
        switch workoutManager.phase {
        case .idle:
            StartView()
        case .countdown:
            CountdownView()
        case .active:
            SessionView()
        case .summary:
            SummaryView()
        }
    }
}
