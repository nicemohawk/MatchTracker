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
            VStack(spacing: 14) {
                HStack(spacing: 14) {
                    controlTile(title: "End", systemImage: "xmark", tint: WatchTheme.loss) {
                        WatchHaptics.stop()
                        Task { await endMatch() }
                    }
                    controlTile(title: isPaused ? "Resume" : "Pause",
                                systemImage: isPaused ? "play.fill" : "pause",
                                tint: WatchTheme.sprint) {
                        WatchHaptics.notify()
                        if isPaused { workoutManager.resume() } else { workoutManager.pause() }
                    }
                }

                HStack(spacing: 14) {
                    controlTile(title: "Lock", systemImage: "drop.fill", tint: WatchTheme.pace) {
                        WatchHaptics.click()
                        WKInterfaceDevice.current().enableWaterLock()
                    }
                    subButton
                }

                if WatchSettings.refereeMode {
                    HStack(spacing: 14) {
                        controlTile(title: "Start Half", systemImage: "play.circle", tint: WatchTheme.turf) {
                            WatchHaptics.click()
                            workoutManager.log(.periodStart)
                        }
                        controlTile(title: "End Half", systemImage: "stop.circle", tint: WatchTheme.sprint) {
                            WatchHaptics.click()
                            workoutManager.log(.periodEnd)
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var subButton: some View {
        let onPitch = workoutManager.onPitch
        let tint = onPitch ? WatchTheme.sprint : WatchTheme.turf
        let button = controlTile(title: onPitch ? "Sub Out" : "Sub In",
                                 systemImage: onPitch ? "figure.walk.motion" : "figure.seated.side",
                                 tint: tint) {
            WatchHaptics.click()
            workoutManager.toggleSub()
        }

        // Optional hands-free double-tap mapping (Settings > Double Tap). Referees are never
        // subbed, so the gesture stays unmapped here in referee mode.
        if #available(watchOS 11.0, *), WatchSettings.doubleTapAction == .subToggle,
           !WatchSettings.refereeMode {
            button.handGestureShortcut(.primaryAction)
        } else {
            button
        }
    }

    /// One Apple-Workout-style control: a round tinted button with its label beneath.
    private func controlTile(title: String, systemImage: String, tint: Color,
                             action: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Button(action: action) {
                Image(systemName: systemImage)
            }
            .buttonStyle(WatchControlButtonStyle(tint: tint))

            Text(title)
                .watchCaptionLabel()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func endMatch() async {
        await workoutManager.endMatch()
    }
}
