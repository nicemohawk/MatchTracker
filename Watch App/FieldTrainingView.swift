//
//  FieldTrainingView.swift
//  MatchTracker
//

import SwiftUI
import MatchTrackerKit

/// Modernized touchline-training flow: walk the perimeter of the pitch to define a field.
/// Shows live distance, auto-finishes when the loop closes, then fits a rectangle and saves +
/// shares the trained field.
///
/// This is a reskin only — every recording decision (sample accuracy gate, loop-close detection,
/// rectangle fit, save + connectivity broadcast) lives in `FieldTrainer` and is untouched. The
/// elapsed clock here is view-side presentation and never feeds the recorded outline.
struct FieldTrainingView: View {
    @Environment(ConnectivityManager.self) private var connectivity
    @Environment(\.dismiss) private var dismiss
    @State private var trainer = FieldTrainer()
    @State private var name = "New Field"
    /// When the current walk began, for the elapsed read-out. View-only; not part of recording.
    @State private var walkStartedAt: Date?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                switch trainer.state {
                case .idle:
                    idleContent
                case .walking:
                    walkingContent
                case .finished:
                    finishedContent
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
        }
        .navigationTitle("Train Field")
        // If the player swipes back mid-walk, stop the location updates so no recording is left
        // running in the background.
        .onDisappear {
            if trainer.state == .walking { trainer.cancel() }
        }
    }

    // MARK: - Idle: explain the walk, offer a prominent start

    private var idleContent: some View {
        VStack(spacing: 12) {
            VStack(spacing: 6) {
                Image(systemName: "figure.walk.motion")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(WatchTheme.pace)
                Text("Touchline Walk")
                    .font(.headline)
                Text("Map this pitch by walking its lines.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 10)
            .watchCard()

            stepRow(number: "1", text: "Start at a corner flag")
            stepRow(number: "2", text: "Walk the lines, steady pace")
            stepRow(number: "3", text: "Return to start to finish")

            Button {
                WatchHaptics.click()
                walkStartedAt = Date()
                trainer.start()
            } label: {
                Label("Start Walking", systemImage: "figure.walk")
                    .font(.headline)
            }
            .buttonStyle(WatchTileButtonStyle(tint: WatchTheme.pace, minHeight: 54, prominent: true))
        }
    }

    /// A numbered instruction line inside a quiet tile, so the three steps read as a checklist.
    private func stepRow(number: String, text: String) -> some View {
        HStack(spacing: 10) {
            Text(number)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(WatchTheme.pace)
                .frame(width: 22, height: 22)
                .background(Circle().fill(WatchTheme.chipFill(WatchTheme.pace)))
            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .watchTile(tint: WatchTheme.pace)
    }

    // MARK: - Walking: live distance, elapsed, points, prominent stop

    private var walkingContent: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text("Walking Touchline")
                    .watchCaptionLabel()
                    .foregroundStyle(WatchTheme.pace)
                Text(String(format: "%.0f", trainer.distanceWalked))
                    .watchHeroNumeral()
                    .foregroundStyle(WatchTheme.pace)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: trainer.distanceWalked)
                Text("meters walked")
                    .watchCaptionLabel()
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .watchCard()

            HStack(spacing: 8) {
                // A per-second timeline ticks the elapsed clock without touching recording state.
                TimelineView(.periodic(from: walkStartedAt ?? .now, by: 1)) { context in
                    walkStat(value: elapsedString(from: walkStartedAt, now: context.date),
                             caption: "Elapsed", tint: WatchTheme.signal)
                }
                walkStat(value: "\(trainer.sampleCount)", caption: "Points", tint: WatchTheme.turf)
            }

            Label("Return to your start to finish", systemImage: "arrow.uturn.backward")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Button {
                WatchHaptics.stop()
                trainer.finish()
            } label: {
                Label("Finish Now", systemImage: "stop.fill")
                    .font(.headline)
            }
            .buttonStyle(WatchTileButtonStyle(tint: WatchTheme.sprint, minHeight: 52))
        }
    }

    /// A single live-walk stat tile (elapsed / points).
    private func walkStat(value: String, caption: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .watchStatNumeral()
                .foregroundStyle(tint)
            Text(caption)
                .watchCaptionLabel()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .watchTile(tint: tint)
    }

    // MARK: - Finished: success + name + save

    private var finishedContent: some View {
        VStack(spacing: 12) {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(WatchTheme.turf)
                Text("Loop Complete")
                    .font(.headline)
                Text(String(format: "%.0f m walked", trainer.distanceWalked))
                    .watchStatNumeral()
                    .foregroundStyle(WatchTheme.turf)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .watchCard()

            VStack(alignment: .leading, spacing: 6) {
                Text("Field name")
                    .watchCaptionLabel()
                    .foregroundStyle(.secondary)
                TextField("Field name", text: $name)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .watchTile(tint: WatchTheme.bench)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                saveField()
            } label: {
                Label("Save Field", systemImage: "checkmark")
                    .font(.headline)
            }
            .buttonStyle(WatchTileButtonStyle(tint: WatchTheme.turf, minHeight: 50, prominent: true))
            .disabled(trainer.makeField(named: name) == nil)

            Button {
                WatchHaptics.click()
                dismiss()
            } label: {
                Label("Discard", systemImage: "xmark")
            }
            .buttonStyle(WatchTileButtonStyle(tint: WatchTheme.bench, minHeight: 44))
        }
    }

    private func saveField() {
        guard let field = trainer.makeField(named: name) else { return }
        try? AppGroupStorage.fieldStore.save(field)
        connectivity.send(field: field)
        WatchHaptics.success()
        dismiss()
    }

    /// Formats elapsed seconds as m:ss between `start` and `now`. Zero when not walking yet.
    private func elapsedString(from start: Date?, now: Date) -> String {
        guard let start else { return "0:00" }
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
