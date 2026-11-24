//
//  MatchTrackerWatchApp.swift
//  MatchTracker
//

import HealthKit
import SwiftUI
import MatchTrackerKit

@main
struct MatchTrackerWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var workoutManager = WorkoutManager.shared
    @State private var connectivity = ConnectivityManager.shared

    init() {
        // Before any view reads a setting: views seed their state from the mirror, so priming it
        // later made the start screen forget the last-used format.
        WatchSettings.prime()
    }

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
                        _ = AppGroupStorage.fieldStore
                    }
                    // The HealthKit calls are independent — run them concurrently.
                    async let authorization: Void = workoutManager.requestAuthorization()
                    async let recovery: Void = workoutManager.recoverActiveWorkoutSession()
                    _ = await (authorization, recovery)
                }
                .onChange(of: scenePhase) { _, phase in
                    // Not journaled mid-match: every wrist raise is three of these, and they were
                    // pushing the lines that matter out of the journal.
                    if workoutManager.phase != .active {
                        MatchLog.info("scene phase -> \(String(describing: phase))", category: "lifecycle")
                    }
                    if phase == .active {
                        workoutManager.appBecameActive()
                    } else {
                        workoutManager.appResignedActive()
                    }
                }
                .onOpenURL { url in
                    // Widget deep link: jump straight into the pre-match countdown.
                    guard url.scheme == "matchtracker", url.host == "start",
                          workoutManager.phase == .idle else { return }
                    workoutManager.beginCountdown(field: workoutManager.detectedField,
                                                  format: WatchSettings.predictedFormat)
                }
        }
    }
}

/// Handles crash recovery of an interrupted workout, per Apple's recommended flow.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func handleActiveWorkoutRecovery() {
        Task { await WorkoutManager.shared.recoverActiveWorkoutSession() }
    }

    /// "Start on Apple Watch", tapped on the phone. The same as tapping Start here.
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        Task { @MainActor in
            let manager = WorkoutManager.shared
            // A match that was interrupted outranks a new one, and comes back by itself.
            await manager.recoverActiveWorkoutSession()
            guard manager.phase == .idle else {
                MatchLog.info("phone start ignored (phase \(manager.phase))", category: "workout")
                return
            }
            MatchLog.info("start requested from the phone", category: "workout")
            manager.beginCountdown(
                field: manager.detectedField,
                format: workoutConfiguration.locationType == .indoor ? .indoor : WatchSettings.predictedFormat)
        }
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
