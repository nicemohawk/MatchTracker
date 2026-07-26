//
//  MatchTrackerWatchApp.swift
//  MatchTracker
//

import SwiftUI
import MatchTrackerKit

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
                    // Persistent lifecycle journal — exported (via the phone) in diagnostics so
                    // a session can be reconstructed after the fact.
                    MatchLog.enableJournal(
                        at: AppGroupStorage.containerURL.appendingPathComponent("journal-watch.jsonl"),
                        deviceTag: "watch")
                    connectivity.activate()
                    // Prime the field store (a full fields.json decode) off the main thread so
                    // StartView's first field detection doesn't pay for it mid-render.
                    Task.detached(priority: .userInitiated) { _ = AppGroupStorage.fieldStore }
                    // The HealthKit calls are independent — run them concurrently.
                    async let authorization: Void = workoutManager.requestAuthorization()
                    async let recovery: Void = workoutManager.recoverActiveWorkoutSession()
                    _ = await (authorization, recovery)
                }
                .onOpenURL { url in
                    // Widget deep link: jump straight into the pre-match countdown.
                    guard url.scheme == "matchtracker", url.host == "start",
                          workoutManager.phase == .idle else { return }
                    workoutManager.phase = .countdown
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
