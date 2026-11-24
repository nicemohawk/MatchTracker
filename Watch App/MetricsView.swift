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
            // Sized to the watch, not to a text style: digits carry a lot of built-in leading,
            // so each line is given less height than its font asks for.
            let height = proxy.size.height
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    ElapsedTimeText(size: height * 0.42).frame(height: height * 0.32)
                    heartRate(size: height * 0.33).frame(height: height * 0.25)
                    distance(size: height * 0.33).frame(height: height * 0.25)
                }
                .scenePadding(.horizontal)
                LiveStatusLine(height: height * 0.18)
                    .frame(height: height * 0.18)
                    .scenePadding(.horizontal)
                    .background { hem }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    /// The bottom of the shirt, with the score on it.
    private var hem: some View {
        VStack(spacing: 2) {
            WatchTheme.ivory.frame(height: 2)
            Cloth.green
        }
        .opacity(isLuminanceReduced ? 0.4 : 1)
        .accessibilityHidden(true)
    }

    private func heartRate(size: CGFloat) -> some View {
        let bpm = Int(workoutManager.heartRate)
        return GlanceMetric(value: bpm > 0 ? "\(bpm)" : "--", unit: "BPM", size: size,
                            tint: WatchTheme.heart.opacity(isLuminanceReduced ? 0.65 : 1)) {
            Image(systemName: "heart.fill")
                .foregroundStyle(WatchTheme.heart.opacity(isLuminanceReduced ? 0.65 : 1))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heart rate")
        .accessibilityValue(bpm > 0 ? "\(bpm) beats per minute" : "No reading")
    }

    private func distance(size: CGFloat) -> some View {
        let measure = UnitSystem.current.distance(workoutManager.distanceMeters)
        return GlanceMetric(value: measure.value, unit: measure.unit.uppercased(), size: size,
                            tint: WatchTheme.ivory.opacity(isLuminanceReduced ? 0.65 : 1)) { EmptyView() }
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
                .font(.glance(size))
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(unit)
                .font(.glance(size * 0.4))
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
                .font(.glance(size))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(WatchTheme.ivory.opacity(isLuminanceReduced ? 0.65 : 1))
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

/// The score, and whatever is wrong. A problem is put in words when it's news; after that its icon
/// keeps watch beside the score.
private struct LiveStatusLine: View {
    let height: CGFloat

    @Environment(WorkoutManager.self) private var workoutManager
    @State private var latestWarning: String?
    @State private var spelledOut: String?

    private struct Warning {
        let text: String
        let systemImage: String
        var isAlwaysSpelledOut = false
    }

    var body: some View {
        let warning = warning
        ViewThatFits(in: .horizontal) {
            if hasScore, let warning, isSpelledOut(warning) {
                line { score; Spacer(minLength: 8); label(warning) }
            }
            if let warning, isSpelledOut(warning), !hasScore || !warning.isAlwaysSpelledOut {
                line { label(warning); Spacer(minLength: 0) }
            }
            line {
                if hasScore { score }
                Spacer(minLength: 0)
                if let warning { label(warning).labelStyle(.iconOnly) }
            }
        }
        .lineLimit(1)
        .task(id: warning?.text) {
            // Coming back to this page isn't news.
            let text = warning?.text
            guard text != latestWarning else { return }
            latestWarning = text
            spelledOut = text
            try? await Task.sleep(for: .seconds(10))
            if spelledOut == text { spelledOut = nil }
        }
    }

    private func line(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 0, content: content)
            // Keeps clear of the display's rounded corner.
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hasScore: Bool { workoutManager.score.us + workoutManager.score.them > 0 }

    private var score: some View {
        Text("\(workoutManager.score.us)–\(workoutManager.score.them)")
            .font(.glance(height * 0.95))
            .monospacedDigit()
            .accessibilityLabel("Score, us \(workoutManager.score.us), them \(workoutManager.score.them)")
    }

    private func label(_ warning: Warning) -> some View {
        Label(warning.text, systemImage: warning.systemImage)
            .font(.system(size: height * 0.52, weight: .semibold))
            .foregroundStyle(WatchTheme.sprint)
    }

    /// Alone on the line there's no reason to abbreviate.
    private func isSpelledOut(_ warning: Warning) -> Bool {
        !hasScore || warning.isAlwaysSpelledOut || spelledOut == warning.text
    }

    private var warning: Warning? {
        if workoutManager.sessionState == .paused {
            return Warning(text: "Paused", systemImage: "pause.fill", isAlwaysSpelledOut: true)
        }
        if workoutManager.usesGPS, let problem = gpsProblem {
            return Warning(text: problem, systemImage: "location.slash.fill")
        }
        if workoutManager.healthCollectionStalled {
            return Warning(text: "No heart rate", systemImage: "heart.slash.fill")
        }
        return nil
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
    @State private var confirmation: Confirmation?

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 8) {
                    whileOff.frame(height: proxy.size.height)
                    // The one calm moment to catch the score up.
                    ScoreTiles(height: proxy.size.height * 0.62, confirmation: $confirmation)
                    if !workoutManager.keepsScore { MomentTile(confirmation: $confirmation) }
                }
            }
        }
        .scenePadding(.horizontal)
        .confirmationOverlay($confirmation)
    }

    private var whileOff: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let questionable = workoutManager.questionableSubOut(at: context.date)
            VStack(alignment: .leading, spacing: 8) {
                Text(questionable == nil ? "On the bench" : "Looks like you came off")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .minimumScaleFactor(0.7)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(benchTime(at: context.date))
                        .font(.kit(76))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .foregroundStyle(WatchTheme.ivory.opacity(isLuminanceReduced ? 0.65 : 1))
                    Spacer(minLength: 0)
                    if workoutManager.heartRate > 0 { heartRate }
                }
                Spacer(minLength: 0)
                Button {
                    if let questionable { workoutManager.stillOn(after: questionable) } else { workoutManager.toggleSub() }
                } label: {
                    Label(questionable == nil ? "Back On" : "Still On", systemImage: "figure.run")
                        .font(.title3.weight(.bold))
                }
                .buttonStyle(WatchTileButtonStyle(tint: WatchTheme.turf, minHeight: 64, prominent: true))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heartRate: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text("\(Int(workoutManager.heartRate))")
                .font(.kit(32))
                .monospacedDigit()
                .contentTransition(.numericText())
            Image(systemName: "heart.fill").font(.system(size: 15))
        }
        .foregroundStyle(WatchTheme.heart.opacity(isLuminanceReduced ? 0.65 : 1))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heart rate")
        .accessibilityValue("\(Int(workoutManager.heartRate)) beats per minute")
    }

    private func benchTime(at date: Date) -> String {
        let seconds = date.timeIntervalSince(workoutManager.benchedSince ?? date)
        return isLuminanceReduced ? "\(Int(seconds / 60)) min"
                                  : MatchTrackerFormat.hoursMinutesSeconds(max(0, seconds))
    }
}
