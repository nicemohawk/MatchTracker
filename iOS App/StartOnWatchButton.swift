// StartOnWatchButton.swift
// MatchTracker

import HealthKit
import Observation
import SwiftUI
import WatchConnectivity
import MatchTrackerKit

/// Opens MatchTracker on the watch and has it begin recording.
@MainActor
@Observable
final class StartOnWatch {
    private(set) var isStarting = false
    /// Bumped when the watch accepts, for feedback.
    private(set) var startedCount = 0
    var failure: String?

    /// Whether there's a watch to start on. Health answers for pairing too late to be useful.
    static var isAvailable: Bool {
        guard HKHealthStore.isHealthDataAvailable(), WCSession.isSupported() else { return false }
        let session = WCSession.default
        return session.activationState == .activated && session.isPaired && session.isWatchAppInstalled
    }

    /// The configuration can't carry a format, so `.unknown` means "whatever you'd guess" — the
    /// watch knows what's usually played on this weekday.
    func start(indoor: Bool = false) {
        guard !isStarting else { return }
        isStarting = true
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .soccer
        configuration.locationType = indoor ? .indoor : .unknown
        Task {
            do {
                try await HealthKitService.shared.healthStore.startWatchApp(toHandle: configuration)
                startedCount += 1
            } catch {
                MatchLog.error("startWatchApp failed: \(error.localizedDescription)", category: "connectivity")
                failure = "Your Apple Watch didn't answer. Check that it's on your wrist, unlocked and nearby, then try again."
            }
            isStarting = false
        }
    }
}

/// "Start on Apple Watch". Draws nothing when there's no watch with the app on it. Style it like any
/// button: `StartOnWatchButton().buttonStyle(.prominentAction)`.
struct StartOnWatchButton: View {
    @State private var model = StartOnWatch()
    @State private var isAvailable = StartOnWatch.isAvailable
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if isAvailable {
            Button {
                model.start()
            } label: {
                Label("Start on Apple Watch", systemImage: "applewatch")
            }
            .disabled(model.isStarting)
            .accessibilityHint("Opens MatchTracker on your watch and starts recording")
            .contextMenu {
                Button("Start Indoor Match", systemImage: "house") { model.start(indoor: true) }
            }
            .sensoryFeedback(.success, trigger: model.startedCount)
            .startOnWatchAlert(model)
        } else {
            // Pairing is known once the session activates, moments after launch.
            Color.clear.frame(height: 0)
                .task(id: scenePhase) {
                    for _ in 0..<5 where !isAvailable {
                        isAvailable = StartOnWatch.isAvailable
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
                .accessibilityHidden(true)
        }
    }
}

extension View {
    func startOnWatchAlert(_ model: StartOnWatch) -> some View {
        alert("Couldn't Start on Apple Watch",
              isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
            Button("Try Again") { model.start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.failure ?? "")
        }
    }
}
