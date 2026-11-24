//
//  ControlsView.swift
//  MatchTracker
//

import SwiftUI
import WatchKit
import MatchTrackerKit

/// The live session's controls: four tiles that fill the screen, so each can be hit without
/// looking for it.
struct ControlsView: View {
    @Environment(WorkoutManager.self) private var workoutManager
    @State private var confirmingEnd = false
    /// When they left, if they've already gone.
    @State private var leftAt: Date?

    private var isPaused: Bool { workoutManager.sessionState == .paused }

    var body: some View {
        GeometryReader { proxy in
            let tileHeight = (proxy.size.height - 8) / 2
            ScrollView {
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        tile("End", systemImage: "xmark", tint: WatchTheme.loss, height: tileHeight) {
                            logTap("End")
                            WatchHaptics.click()
                            leftAt = workoutManager.leftThePitchAt
                            confirmingEnd = true
                        }
                        tile(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill",
                             tint: WatchTheme.sprint, height: tileHeight) {
                            logTap(isPaused ? "Resume" : "Pause")
                            WatchHaptics.notify()
                            if isPaused { workoutManager.resume() } else { workoutManager.pause() }
                        }
                    }
                    GridRow {
                        tile("Lock", systemImage: "drop.fill", tint: WatchTheme.pace, height: tileHeight) {
                            WatchHaptics.click()
                            WKInterfaceDevice.current().enableWaterLock()
                        }
                        if WatchSettings.refereeMode {
                            tile("Half", systemImage: "flag.fill", tint: WatchTheme.turf, height: tileHeight) {
                                WatchHaptics.click()
                                workoutManager.log(workoutManager.periodInProgress ? .periodEnd : .periodStart)
                            }
                        } else {
                            subTile(height: tileHeight)
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .scenePadding(.horizontal)
        // An accidental End costs the rest of the match, and End is one sleeve-brush away.
        .confirmationDialog("End this match?", isPresented: $confirmingEnd, titleVisibility: .visible) {
            if let leftAt {
                Button("End at \(leftAt.formatted(date: .omitted, time: .shortened))") { end(at: leftAt) }
            }
            Button(leftAt == nil ? "End Match" : "End Now", role: .destructive) { end(at: nil) }
            Button("Keep Playing", role: .cancel) {}
        } message: {
            if leftAt != nil { Text("You've left the pitch. Ending when you left keeps the way home out of it.") }
        }
    }

    private func end(at date: Date?) {
        WatchHaptics.stop()
        Task { await workoutManager.endMatch(at: date, hadLeft: date != nil) }
    }

    @ViewBuilder
    private func subTile(height: CGFloat) -> some View {
        let onPitch = workoutManager.onPitch
        let button = tile(onPitch ? "Sub Out" : "Back On",
                          systemImage: onPitch ? "figure.walk.departure" : "figure.run",
                          tint: onPitch ? WatchTheme.bench : WatchTheme.turf, height: height) {
            workoutManager.toggleSub()
        }
        if #available(watchOS 11.0, *), WatchSettings.doubleTapAction == .subToggle {
            button.handGestureShortcut(.primaryAction)
        } else {
            button
        }
    }

    private func tile(_ title: String, systemImage: String, tint: Color, height: CGFloat,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.title2.weight(.semibold))
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .buttonStyle(WatchTileButtonStyle(tint: tint, minHeight: height))
    }

    /// Journal the tap before the manager sees it, with the state the button was rendered from.
    private func logTap(_ name: String) {
        MatchLog.info("user: tapped \(name) (phase \(workoutManager.phase), sessionState \(workoutManager.sessionState.rawValue))",
                      category: "ui")
    }
}
