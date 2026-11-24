//
//  MetricsView.swift
//  MatchTracker
//

import SwiftUI
import MatchTrackerKit

/// The page a raised wrist lands on. It answers one question per moment:
/// - On the pitch, a glance: time, heart rate, distance, as large as the watch allows. Nothing here
///   is tappable, because nobody taps mid-play and sleeves do.
/// - On the bench, where there's time and a free hand: how long you've been off, and one big
///   button to come back on.
struct MetricsView: View {
    @Environment(WorkoutManager.self) private var workoutManager

    var body: some View {
        if workoutManager.onPitch || WatchSettings.refereeMode {
            PitchGlance()
        } else {
            BenchView()
        }
    }
}

// MARK: - On the pitch

private struct PitchGlance: View {
    @Environment(WorkoutManager.self) private var workoutManager
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        GeometryReader { proxy in
            // Sized to the watch, not to a text style: rounded digits carry a lot of built-in leading,
            // so each line is given less height than its font asks for.
            let height = proxy.size.height
            VStack(alignment: .leading, spacing: 0) {
                ElapsedTimeText(size: height * 0.36).frame(height: height * 0.32)
                heartRate(size: height * 0.32).frame(height: height * 0.28)
                distance(size: height * 0.32).frame(height: height * 0.28)
                LiveStatusLine().frame(height: height * 0.12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scenePadding(.horizontal)
        .ignoresSafeArea(edges: .bottom)
    }

    private func heartRate(size: CGFloat) -> some View {
        let bpm = Int(workoutManager.heartRate)
        return GlanceMetric(value: bpm > 0 ? "\(bpm)" : "--", unit: "BPM", size: size,
                            tint: WatchTheme.heart.opacity(isLuminanceReduced ? 0.65 : 1)) {
            BeatingHeart(bpm: workoutManager.heartRate, animates: !isLuminanceReduced,
                         tint: WatchTheme.heart.opacity(isLuminanceReduced ? 0.65 : 1))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heart rate")
        .accessibilityValue(bpm > 0 ? "\(bpm) beats per minute" : "No reading")
    }

    private func distance(size: CGFloat) -> some View {
        let measure = UnitSystem.current.distance(workoutManager.distanceMeters)
        return GlanceMetric(value: measure.value, unit: measure.unit.uppercased(), size: size,
                            tint: .white.opacity(isLuminanceReduced ? 0.65 : 1)) { EmptyView() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Distance")
            .accessibilityValue(measure.spoken)
    }
}

/// One line of the glance: a numeral that fills its share of the screen, its unit beside it.
private struct GlanceMetric<Accessory: View>: View {
    let value: String
    let unit: String
    let size: CGFloat
    let tint: Color
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(unit)
                .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                .foregroundStyle(tint.opacity(0.8))
            accessory()
                .font(.system(size: size * 0.45))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// The elapsed-time hero in its own view holding the once-a-second TimelineView, so the tick only
/// rebuilds this numeral.
private struct ElapsedTimeText: View {
    let size: CGFloat

    @Environment(WorkoutManager.self) private var workoutManager
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            Text(elapsedString(at: context.date))
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(WatchTheme.cardYellow.opacity(isLuminanceReduced ? 0.65 : 1))
                .contentTransition(.numericText())
        }
        .accessibilityLabel("Elapsed time")
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
}

/// The single most useful thing to say right now, most urgent first: something is wrong, else the
/// score, else nothing.
private struct LiveStatusLine: View {
    @Environment(WorkoutManager.self) private var workoutManager

    var body: some View {
        Group {
            if workoutManager.sessionState == .paused {
                Label("Paused", systemImage: "pause.fill").foregroundStyle(WatchTheme.sprint)
            } else if workoutManager.usesGPS, let problem = gpsProblem {
                Label(problem, systemImage: "location.slash.fill").foregroundStyle(WatchTheme.sprint)
            } else if workoutManager.healthCollectionStalled {
                Label("No heart rate", systemImage: "heart.slash.fill").foregroundStyle(WatchTheme.sprint)
            } else if workoutManager.score.us + workoutManager.score.them > 0 {
                Text("\(workoutManager.score.us) – \(workoutManager.score.them)")
                    .monospacedDigit()
                    .accessibilityLabel("Score, us \(workoutManager.score.us), them \(workoutManager.score.them)")
            } else {
                // Holds the line's height so the numerals above never shift.
                Text(" ").accessibilityHidden(true)
            }
        }
        .font(.headline)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private var gpsProblem: String? {
        switch workoutManager.routeRecorder.signal {
        case .acquiring: return "Finding GPS"
        case .lost: return "GPS lost"
        case .denied: return "Location is off"
        case .imprecise: return "Precise Location off"
        case .good, .off: return nil
        }
    }
}

// MARK: - On the bench

private struct BenchView: View {
    @Environment(WorkoutManager.self) private var workoutManager
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("On the bench")
                .font(.headline)
                .foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(benchTime(at: context.date))
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(.white.opacity(isLuminanceReduced ? 0.65 : 1))
            }
            Spacer(minLength: 0)
            Button {
                workoutManager.toggleSub()
            } label: {
                Label("Back On", systemImage: "figure.run")
                    .font(.title3.weight(.bold))
            }
            .buttonStyle(WatchTileButtonStyle(tint: WatchTheme.turf, minHeight: 64, prominent: true))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scenePadding(.horizontal)
    }

    private func benchTime(at date: Date) -> String {
        let seconds = date.timeIntervalSince(workoutManager.benchedSince ?? date)
        return isLuminanceReduced ? "\(Int(seconds / 60)) min"
                                  : MatchTrackerFormat.hoursMinutesSeconds(max(0, seconds))
    }
}

/// A small heart glyph that gently pulses at a capped, human-readable rate while the display is
/// fully lit; frozen (and dimmed by its tint) in always-on.
private struct BeatingHeart: View {
    let bpm: Double
    let animates: Bool
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Cap the pulse so a 180 bpm sprint doesn't strobe; a resting heart reads as a calm beat.
        let beatsPerSecond = min(max(bpm, 40), 130) / 60
        Image(systemName: "heart.fill")
            .foregroundStyle(tint)
            .symbolEffect(.pulse, options: .speed(beatsPerSecond),
                          isActive: animates && !reduceMotion && bpm > 0)
    }
}
