//
//  MetricsView.swift
//  MatchTracker
//

import SwiftUI

/// Page 2 of the live session: the Apple-Workout-style metrics screen. The elapsed timer is the
/// anchor — a big rounded monospaced numeral — with heart rate (Theme.heart, a subtle beat),
/// distance (pace blue), active calories (sprint amber) and current speed (turf) stacked beneath.
///
/// Supports always-on display: when the luminance is reduced we drop the seconds from the timer,
/// stop the heart animation and dim the palette to save power and reduce burn-in.
struct MetricsView: View {
    @Environment(WorkoutManager.self) private var workoutManager
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        TimelineView(.periodic(from: .now, by: isLuminanceReduced ? 1.0 : 0.05)) { context in
            VStack(alignment: .leading, spacing: 4) {
                Text(elapsedString(at: context.date))
                    .watchHeroNumeral()
                    .foregroundStyle(dim(WatchTheme.cardYellow))
                    .contentTransition(.numericText())

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

    // Only the elapsed-time hero (cardYellow) and heart rate (heart red) keep a saturated accent;
    // the remaining metrics are muted to white/secondary so the hero isn't diluted.
    private var heartRateRow: some View {
        metricRow(
            value: workoutManager.heartRate > 0 ? "\(Int(workoutManager.heartRate))" : "--",
            unit: "BPM",
            valueColor: WatchTheme.heart
        ) {
            BeatingHeart(bpm: workoutManager.heartRate, animates: !isLuminanceReduced, tint: dim(WatchTheme.heart))
        }
    }

    private var distanceRow: some View {
        metricRow(value: distanceString, unit: "KM", valueColor: .white) {
            Image(systemName: "figure.run").foregroundStyle(.secondary)
        }
    }

    private var caloriesRow: some View {
        metricRow(value: "\(Int(workoutManager.activeCalories))", unit: "CAL", valueColor: .white) {
            Image(systemName: "flame.fill").foregroundStyle(.secondary)
        }
    }

    private var speedRow: some View {
        metricRow(value: speedString, unit: "KM/H", valueColor: .white) {
            Image(systemName: "speedometer").foregroundStyle(.secondary)
        }
    }

    private func metricRow<Icon: View>(value: String, unit: String, valueColor: Color, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 6) {
            icon()
                .font(.headline)
                .frame(width: 20)
            Text(value)
                .watchStatNumeral()
                .foregroundStyle(dim(valueColor))
                .contentTransition(.numericText())
            Text(unit)
                .watchCaptionLabel()
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    // MARK: Formatting

    /// Dims a tint in always-on so accents read softly against the reduced-luminance face.
    private func dim(_ color: Color) -> Color {
        color.opacity(isLuminanceReduced ? 0.65 : 1)
    }

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

    // Metric to match the iOS app (MatchFormat.distance renders km everywhere).
    private var distanceString: String {
        String(format: "%.2f", workoutManager.distanceMeters / 1000)
    }

    private var speedString: String {
        String(format: "%.1f", max(0, workoutManager.currentSpeed * 3.6))
    }
}

/// A heart glyph that pulses at the wearer's current heart rate, with the beat magnitude loosely
/// scaled to how hard they're working. Paused and static in always-on.
private struct BeatingHeart: View {
    let bpm: Double
    let animates: Bool
    var tint: Color = WatchTheme.heart
    @State private var enlarged = false

    var body: some View {
        Image(systemName: "heart.fill")
            .foregroundStyle(tint)
            .scaleEffect(enlarged ? peakScale : 0.92)
            .animation(animates ? beatAnimation : .default, value: enlarged)
            .onAppear { if animates { enlarged.toggle() } }
            .onChange(of: animates) { _, isOn in enlarged = isOn ? true : false }
    }

    /// Peak scale grows subtly with intensity: a resting heart barely swells, a maxed-out one
    /// pushes a little harder. Clamped so the pulse always stays gentle.
    private var peakScale: CGFloat {
        let intensity = min(max((bpm - 60) / 120, 0), 1) // 0 at 60 bpm, 1 by 180 bpm
        return 1.05 + 0.1 * intensity
    }

    private var beatAnimation: Animation {
        let interval = bpm > 30 ? 60.0 / bpm : 1.0
        return .easeInOut(duration: interval / 2).repeatForever(autoreverses: true)
    }
}
