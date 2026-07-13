//
//  EventsView.swift
//  MatchTracker
//

import SwiftUI
import MatchTrackerKit

/// Page 3 of the live session: the giant Flag button plus goal/assist logging, the running
/// score and the count of logged events. Every log gives a success haptic and a brief overlay.
struct EventsView: View {
    @Environment(WorkoutManager.self) private var workoutManager
    @State private var confirmation: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                scoreHeader

                flagButton

                HStack(spacing: 8) {
                    eventButton("Goal Us", systemImage: "soccerball", tint: .green, kind: .goalForUs)
                    eventButton("Goal Them", systemImage: "soccerball.inverse", tint: .red, kind: .goalAgainstUs)
                }
                HStack(spacing: 8) {
                    eventButton("My Goal", systemImage: "star.fill", tint: .yellow, kind: .goalMine)
                    eventButton("Assist", systemImage: "hand.thumbsup.fill", tint: .blue, kind: .assist)
                }
            }
            .padding(.horizontal, 4)
        }
        .overlay { confirmationOverlay }
    }

    private var scoreHeader: some View {
        VStack(spacing: 2) {
            Text("\(workoutManager.score.us)–\(workoutManager.score.them)")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("\(workoutManager.loggedEventCount) events")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if autoSubCount > 0 {
                Label("\(autoSubCount) auto", systemImage: "wand.and.stars")
                    .font(.caption2)
                    .foregroundStyle(.teal)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Automatic substitutions detected so far this match.
    private var autoSubCount: Int {
        workoutManager.events.filter {
            $0.source == .automatic && ($0.kind == .subIn || $0.kind == .subOut)
        }.count
    }

    @ViewBuilder
    private var flagButton: some View {
        let button = Button {
            logEvent(.flag, label: "Flagged")
        } label: {
            Label("Flag", systemImage: "flag.fill")
                .font(.title2.weight(.bold))
                .frame(maxWidth: .infinity, minHeight: 64)
        }
        .tint(.purple)

        if #available(watchOS 11.0, *) {
            // Double-tap gesture flags a moment hands-free from anywhere in the session.
            button.handGestureShortcut(.primaryAction)
        } else {
            button
        }
    }

    private func eventButton(_ title: String, systemImage: String, tint: Color, kind: MatchEventKind) -> some View {
        Button {
            logEvent(kind, label: title)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
        }
        .tint(tint)
    }

    @ViewBuilder
    private var confirmationOverlay: some View {
        if let confirmation {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.green)
                Text(confirmation)
                    .font(.headline)
            }
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .transition(.scale.combined(with: .opacity))
        }
    }

    private func logEvent(_ kind: MatchEventKind, label: String) {
        workoutManager.log(kind)
        withAnimation(.snappy) { confirmation = label }
        Task {
            try? await Task.sleep(for: .seconds(1))
            withAnimation(.easeOut) { confirmation = nil }
        }
    }
}
