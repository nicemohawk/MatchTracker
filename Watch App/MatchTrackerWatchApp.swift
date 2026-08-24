//
//  MatchTrackerWatchApp.swift
//  MatchTracker
//

import SwiftUI
import MatchTrackerKit

@main
struct MatchTrackerWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var workoutManager = WorkoutManager.shared
    @State private var connectivity = ConnectivityManager.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(workoutManager)
                .environment(connectivity)
                .task {
                    // Records any stretch where the main thread stops answering, so a frozen UI
                    // is distinguishable from a logic bug in an export.
                    MainThreadWatchdog.shared.start()
                    connectivity.activate()
                    // Resolve the shared container and preferences off the main thread — both are
                    // system round-trips — and prime the field store (a full fields.json decode)
                    // while we're here, so StartView's first detection doesn't pay for it. The
                    // journal lives in that container, so enabling it belongs in the same hop.
                    Task.detached(priority: .userInitiated) {
                        // Persistent lifecycle journal — exported (via the phone) in diagnostics
                        // so a session can be reconstructed after the fact.
                        MatchLog.enableJournal(
                            at: AppGroupStorage.containerURL.appendingPathComponent("journal-watch.jsonl"),
                            deviceTag: "watch")
                        WatchSettings.prime()
                        _ = AppGroupStorage.fieldStore
                    }
                    // The HealthKit calls are independent — run them concurrently.
                    async let authorization: Void = workoutManager.requestAuthorization()
                    async let recovery: Void = workoutManager.recoverActiveWorkoutSession()
                    _ = await (authorization, recovery)
                }
                .onChange(of: scenePhase) { _, phase in
                    // Suspension and a wedged main thread look identical from the outside; only
                    // the journal can separate them, and only if it records this.
                    MatchLog.info("scene phase -> \(String(describing: phase))", category: "lifecycle")
                }
                .onOpenURL { url in
                    // Widget deep link: jump straight into the pre-match countdown.
                    guard url.scheme == "matchtracker", url.host == "start",
                          workoutManager.phase == .idle else { return }
                    workoutManager.beginCountdown(field: workoutManager.detectedField,
                                                  format: workoutManager.matchFormat)
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
        // Journaled on every evaluation: the phase changing without this line following it means
        // the state moved and SwiftUI never re-rendered — a different bug from the state not moving.
        let phase = workoutManager.phase
        MatchLog.info("render: phase \(phase)", category: "ui")
        return Group {
            switch phase {
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
}
