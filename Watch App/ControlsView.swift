//
//  ControlsView.swift
//  MatchTracker
//

import SwiftUI
import WatchKit

/// Page 1 of the live session: End, Pause/Resume, Water Lock and the Sub Out/In toggle.
struct ControlsView: View {
    @Environment(WorkoutManager.self) private var workoutManager

    private var isPaused: Bool { workoutManager.sessionState == .paused }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    controlButton(title: "End", systemImage: "xmark", tint: .red) {
                        Task { await endMatch() }
                    }
                    controlButton(title: isPaused ? "Resume" : "Pause",
                                  systemImage: isPaused ? "play.fill" : "pause",
                                  tint: .yellow) {
                        if isPaused { workoutManager.resume() } else { workoutManager.pause() }
                    }
                }

                HStack(spacing: 10) {
                    controlButton(title: "Lock", systemImage: "drop.fill", tint: .blue) {
                        WKInterfaceDevice.current().enableWaterLock()
                    }
                    subButton
                }

                if WatchSettings.refereeMode {
                    HStack(spacing: 10) {
                        controlButton(title: "Start Half", systemImage: "play.circle", tint: .green) {
                            workoutManager.log(.periodStart)
                        }
                        controlButton(title: "End Half", systemImage: "stop.circle", tint: .orange) {
                            workoutManager.log(.periodEnd)
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private var subButton: some View {
        let button = Button {
            workoutManager.toggleSub()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: workoutManager.onPitch ? "figure.walk.motion" : "figure.seated.side")
                    .font(.title3)
                Text(workoutManager.onPitch ? "Sub Out" : "Sub In")
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
        }
        .tint(workoutManager.onPitch ? .orange : .green)

        // Optional hands-free double-tap mapping (Settings > Double Tap).
        if #available(watchOS 11.0, *), WatchSettings.doubleTapAction == .subToggle {
            button.handGestureShortcut(.primaryAction)
        } else {
            button
        }
    }

    private func controlButton(title: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
        }
        .tint(tint)
    }

    private func endMatch() async {
        await workoutManager.endMatch()
    }
}
