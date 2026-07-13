//
//  MetricsView.swift
//  MatchTracker
//

import SwiftUI

/// Page 2 of the live session: the Apple-Workout-style metrics screen — big yellow elapsed
/// timer, heart rate with a beating heart, distance, active calories and current speed.
///
/// Supports always-on display: when the luminance is reduced we drop the seconds from the timer
/// and stop the heart animation to save power.
struct MetricsView: View {
    @Environment(WorkoutManager.self) private var workoutManager
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        TimelineView(.periodic(from: .now, by: isLuminanceReduced ? 1.0 : 0.05)) { context in
            VStack(alignment: .leading, spacing: 2) {
                Text(elapsedString(at: context.date))
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .foregroundStyle(.yellow)
                    .monospacedDigit()

                heartRateRow
                distanceRow
                caloriesRow
                speedRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
        .scenePadding(.top)
    }

    // MARK: Rows

    private var heartRateRow: some View {
        metricRow(
            value: workoutManager.heartRate > 0 ? "\(Int(workoutManager.heartRate))" : "--",
            unit: "BPM",
            tint: .red
        ) {
            BeatingHeart(bpm: workoutManager.heartRate, animates: !isLuminanceReduced)
        }
    }

    private var distanceRow: some View {
        metricRow(value: distanceString, unit: "MI", tint: .blue) {
            Image(systemName: "figure.run").foregroundStyle(.blue)
        }
    }

    private var caloriesRow: some View {
        metricRow(value: "\(Int(workoutManager.activeCalories))", unit: "CAL", tint: .orange) {
            Image(systemName: "flame.fill").foregroundStyle(.orange)
        }
    }

    private var speedRow: some View {
        metricRow(value: speedString, unit: "MPH", tint: .green) {
            Image(systemName: "speedometer").foregroundStyle(.green)
        }
    }

    private func metricRow<Icon: View>(value: String, unit: String, tint: Color, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 6) {
            icon()
                .font(.headline)
                .frame(width: 20)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    // MARK: Formatting

    private func elapsedString(at date: Date) -> String {
        let elapsed = Int(workoutManager.elapsedTime(at: date).rounded(.down))
        let hours = elapsed / 3600
        let minutes = (elapsed % 3600) / 60
        let seconds = elapsed % 60
        if isLuminanceReduced {
            // Drop seconds in always-on to reduce burn-in and refreshes.
            return hours > 0 ? String(format: "%d:%02d", hours, minutes)
                             : String(format: "%d:--", minutes)
        }
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
                         : String(format: "%d:%02d", minutes, seconds)
    }

    private var distanceString: String {
        let miles = workoutManager.distanceMeters / 1609.344
        return String(format: "%.2f", miles)
    }

    private var speedString: String {
        let milesPerHour = workoutManager.currentSpeed * 2.2369363
        return String(format: "%.1f", max(0, milesPerHour))
    }
}

/// A heart glyph that pulses at the wearer's current heart rate (paused in always-on).
private struct BeatingHeart: View {
    let bpm: Double
    let animates: Bool
    @State private var enlarged = false

    var body: some View {
        Image(systemName: "heart.fill")
            .foregroundStyle(.red)
            .scaleEffect(enlarged ? 1.15 : 0.9)
            .animation(animates ? beatAnimation : .default, value: enlarged)
            .onAppear { if animates { enlarged.toggle() } }
            .onChange(of: animates) { _, isOn in enlarged = isOn ? true : false }
    }

    private var beatAnimation: Animation {
        let interval = bpm > 30 ? 60.0 / bpm : 1.0
        return .easeInOut(duration: interval / 2).repeatForever(autoreverses: true)
    }
}
