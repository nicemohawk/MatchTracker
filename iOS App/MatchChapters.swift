// MatchChapters.swift
// MatchTracker

import Charts
import MatchTrackerKit
import SwiftUI

// MARK: - Moments

/// What happened, not what was logged: goals, cards and flags, with halves as dividers. Automatic
/// subs and period markers are folded into "time on the bench" and stay out of the way.
struct MomentsChapter: View {
    @ObservedObject var detail: MatchDetailModel
    let onEdit: () -> Void
    /// Plays a moment on the pitch; nil when there is none to play it on.
    var onShow: ((MatchEvent) -> Void)?

    @ObservedObject private var videos = SidelineVideoStore.shared
    @State private var clip: ClipSelection?

    static func isMoment(_ kind: MatchEventKind) -> Bool {
        switch kind {
        case .matchStart, .matchEnd, .periodStart, .periodEnd, .subIn, .subOut: return false
        default: return true
        }
    }

    private var moments: [MatchEvent] {
        detail.events.filter { Self.isMoment($0.kind) && detail.playedInterval.contains($0.date) }
            .sorted { $0.date < $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Moments").font(.title2.bold())
                Spacer()
                Button("Edit", action: onEdit)
            }
            if moments.isEmpty && bench == nil {
                Button(action: onEdit) {
                    Label("Add goals and moments", systemImage: "plus.circle.fill")
                        .font(.body)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(moments) { event in
                        let footage = ClipSelection.of(event, in: detail)
                        MomentRow(event: event, minutes: detail.minutes,
                                  onShow: onShow.map { onShow in { onShow(event) } },
                                  onPlay: footage.map { footage in { clip = footage } })
                    }
                    if let bench {
                        Label(bench, systemImage: "figure.seated.side")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .sheet(item: $clip) { MomentClipView(selection: $0) }
    }

    private var bench: String? {
        let seconds = detail.playedInterval.duration - (detail.digest?.secondsOnPitch ?? detail.playedInterval.duration)
            - (detail.analytics?.halftime?.duration ?? 0)
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 3 ? "\(minutes) min on the bench" : nil
    }

}

private struct MomentRow: View {
    let event: MatchEvent
    let minutes: MatchMinutes
    var onShow: (() -> Void)?
    var onPlay: (() -> Void)?

    var body: some View {
        HStack(spacing: 14) {
            if let onShow {
                Button(action: onShow) { moment }
                    .buttonStyle(.plain)
                    .accessibilityLabel(spoken)
                    .accessibilityHint("Plays it on the pitch")
            } else {
                moment
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spoken)
            }
            if let onPlay {
                Button("Play Video", systemImage: "play.circle.fill", action: onPlay)
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Play video, \(spoken)")
            }
        }
    }

    private var spoken: String {
        [minutes.spoken(for: event.date), event.kind.momentTitle, event.note ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var moment: some View {
        HStack(spacing: 14) {
            Text(minutes.text(for: event.date))
                .font(.system(.body, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(onShow == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(minWidth: 44, alignment: .leading)
            Image(systemName: event.kind.momentSymbol)
                .font(.title3)
                .foregroundStyle(event.kind.momentColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.kind.momentTitle).font(.body.weight(event.kind == .goalMine ? .semibold : .regular))
                if let note = event.note, !note.isEmpty {
                    Text(note).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension MatchEventKind {
    var momentTitle: String {
        switch self {
        case .goalForUs: return "Goal"
        case .goalMine: return "You scored"
        case .assist: return "Your assist"
        case .goalAgainstUs: return "They scored"
        case .flag: return "Flagged moment"
        case .yellowCard: return "Yellow card"
        case .redCard: return "Red card"
        case .foul: return "Foul"
        case .turnover: return "Turnover"
        case .timeout: return "Timeout"
        case .subIn: return "Came on"
        case .subOut: return "Came off"
        case .periodStart: return "Half started"
        case .periodEnd: return "Half ended"
        case .matchStart: return "Kickoff"
        case .matchEnd: return "Full time"
        }
    }

    var momentSymbol: String {
        switch self {
        case .goalForUs, .goalAgainstUs: return "soccerball"
        case .goalMine: return "soccerball.inverse"
        case .assist: return "hand.thumbsup.fill"
        case .flag: return "flag.fill"
        case .yellowCard, .redCard: return "rectangle.portrait.fill"
        case .foul: return "exclamationmark.triangle.fill"
        case .subIn: return "arrow.up.forward"
        case .subOut: return "arrow.down.backward"
        default: return "clock"
        }
    }

    var momentColor: Color {
        switch self {
        case .goalForUs, .goalMine, .assist: return .green
        case .goalAgainstUs, .redCard: return .red
        case .yellowCard: return .yellow
        default: return .secondary
        }
    }
}

// MARK: - Best runs

struct BestRunsChapter: View {
    let runs: [KeyRun]
    let minutes: MatchMinutes
    /// Plays a run on the pitch.
    let onShow: (KeyRun) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Best runs").font(.title2.bold())
            VStack(spacing: 0) {
                ForEach(runs) { run in
                    Button { onShow(run) } label: { row(run) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(spoken(run))
                        .accessibilityHint("Plays it on the pitch")
                }
            }
        }
    }

    private func start(of run: KeyRun) -> Date { run.segment.interval.start }

    private func spoken(_ run: KeyRun) -> String {
        let units = UnitSystem.current
        return [run.title, "\(units.speed(run.peakSpeed).spoken) over \(units.shortDistance(run.distanceMeters).spoken)",
                minutes.spoken(for: start(of: run)), run.detail].compactMap { $0 }.joined(separator: ", ")
    }

    private func row(_ run: KeyRun) -> some View {
        let isLarge = dynamicTypeSize.isAccessibilitySize
        let layout = isLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 14))
        return layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(run.title).font(.body)
                (Text(minutes.text(for: start(of: run))).foregroundStyle(.tint)
                    + Text(run.detail.map { " · \($0)" } ?? ""))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !isLarge { Spacer(minLength: 8) }
            VStack(alignment: isLarge ? .leading : .trailing, spacing: 2) {
                Text(UnitSystem.current.speed(run.peakSpeed).text)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                Text(UnitSystem.current.shortDistance(run.distanceMeters).text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .padding(.vertical, isLarge ? 6 : 0)
        .contentShape(Rectangle())
    }
}

// MARK: - Effort

/// How hard it was, in a word and one chart.
struct EffortChapter: View {
    @ObservedObject var detail: MatchDetailModel
    let analytics: MatchAnalytics

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Effort").font(.title2.bold())
            if let word = Self.word(for: detail.digest?.effort) {
                Text(word).font(.title3)
            }
            if !detail.heartRateSeries.isEmpty {
                HeartRateChart(series: detail.heartRateSeries, start: detail.matchStart, halftime: analytics.halftime)
                    .frame(height: 180)
            }
            EffortRatingRow(workout: detail.workout)
            NavigationLink {
                AllNumbersView(detail: detail, analytics: analytics)
            } label: {
                HStack {
                    Text("All numbers")
                    Spacer()
                    Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    static func word(for effort: Double?) -> String? {
        guard let effort else { return nil }
        switch effort {
        case ..<30: return "Easy"
        case ..<50: return "Moderate"
        case ..<70: return "Hard"
        default: return "All out"
        }
    }
}

/// For a match with no pitch to draw, the heart is the picture.
struct HeartRateHero: View {
    let series: [(date: Date, bpm: Double)]
    let start: Date

    var body: some View {
        HeartRateChart(series: series, start: start, halftime: nil)
            .frame(height: 260)
    }
}

struct HeartRateChart: View {
    let series: [(date: Date, bpm: Double)]
    let start: Date
    let halftime: DateInterval?

    @State private var selectedMinute: Double?
    /// For "HT", above the plot.
    @ScaledMetric(relativeTo: .footnote) private var headroom = 22.0

    private struct Point: Identifiable {
        let id: Int
        let isSecondHalf: Bool
        let minute: Double
        let bpm: Double
    }

    private var minutes: MatchMinutes { MatchMinutes(kickoff: start, halftime: halftime) }

    /// One point a minute: enough shape, and it draws instantly. Half-time isn't a minute of anything.
    private var points: [Point] {
        let minutes = minutes
        let played = series.filter { $0.date >= start && !minutes.isHalftime($0.date) }
            .map { (isSecondHalf: $0.date >= (halftime?.end ?? .distantFuture),
                    minute: minutes.playedSeconds(at: $0.date) / 60, bpm: $0.bpm) }
        // The minute half-time fell in has a point on either side of it.
        let byMinute = Dictionary(grouping: played) { Int($0.minute) * 2 + ($0.isSecondHalf ? 1 : 0) }
        return byMinute.sorted { $0.key < $1.key }.map { key, samples in
            let count = Double(samples.count)
            return Point(id: key, isSecondHalf: samples[0].isSecondHalf, minute: samples.reduce(0) { $0 + $1.minute } / count,
                         bpm: samples.reduce(0) { $0 + $1.bpm } / count)
        }
    }

    var body: some View {
        let points = points
        let selected = selectedMinute.flatMap { minute in
            points.min { abs($0.minute - minute) < abs($1.minute - minute) }
        }
        let lowest = ((points.map(\.bpm).min() ?? 60) / 20).rounded(.down) * 20
        let highest = max(((points.map(\.bpm).max() ?? 180) / 20).rounded(.up) * 20, lowest + 20)
        Chart {
            if let halftime { halftimeRule(halftime) }
            ForEach(points) { line($0) }
            if let selected { callout(selected) }
        }
        .chartYScale(domain: lowest...highest)
        .chartXSelection(value: $selectedMinute)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisValueLabel { if let minute = value.as(Double.self) { Text("\(Int(minute))′") } }
            }
        }
        .padding(.top, halftime == nil ? 0 : headroom)
        .accessibilityLabel("Heart rate through the match")
    }

    private func halftimeRule(_ halftime: DateInterval) -> some ChartContent {
        RuleMark(x: .value("Minute", minutes.playedSeconds(at: halftime.start) / 60))
            .lineStyle(StrokeStyle(lineWidth: 1))
            .foregroundStyle(Color(.systemGray3))
            .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                Text("HT").font(.footnote).foregroundStyle(.secondary)
            }
            .accessibilityLabel("Half-time")
    }

    private func line(_ point: Point) -> some ChartContent {
        LineMark(x: .value("Minute", point.minute), y: .value("Heart rate", point.bpm),
                 series: .value("Half", point.isSecondHalf ? 2 : 1))
            .interpolationMethod(.monotone)
            .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
            .foregroundStyle(Color.pink)
    }

    private func callout(_ point: Point) -> some ChartContent {
        RuleMark(x: .value("Minute", point.minute))
            .foregroundStyle(Color.secondary)
            .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                Text("\(Int(point.bpm)) bpm · \(Int(point.minute) + 1)′")
                    .font(.headline)
                    .monospacedDigit()
            }
    }
}

// MARK: - All numbers

/// Every measurement, as a list. No composite anything: each row says what it is.
struct AllNumbersView: View {
    @ObservedObject var detail: MatchDetailModel
    let analytics: MatchAnalytics

    var body: some View {
        List {
            Section("Running") {
                if let meters = analytics.distanceMeters { row("Distance", UnitSystem.current.distance(meters)) }
                if let speed = analytics.topSpeedMetersPerSecond {
                    row("Top speed", UnitSystem.current.speed(speed), note: "Held for at least a second")
                }
                if analytics.hasRoute {
                    row("Runs", "\(analytics.runs.runCount)", note: "Faster than \(UnitSystem.current.speed(SpeedThresholds.running).text) for two seconds")
                    row("Sprints", "\(analytics.runs.sprintCount)", note: "Faster than \(UnitSystem.current.speed(SpeedThresholds.sprinting).text)")
                }
                if let load = analytics.loadMetrics {
                    row("Distance sprinting", UnitSystem.current.shortDistance(load.sprintDistanceMeters))
                    row("Distance per minute", UnitSystem.current.shortDistance(load.distancePerMinuteMeters))
                }
            }
            Section("Time") {
                row("On the pitch", MatchTrackerFormat.hoursMinutesSeconds(analytics.workrate.timeOnPitch))
                row("Match", MatchTrackerFormat.hoursMinutesSeconds(analytics.interval.duration))
                if let halftime = analytics.halftime {
                    row("Half-time", MatchTrackerFormat.hoursMinutesSeconds(halftime.duration))
                }
            }
            if let thirds = analytics.thirds {
                Section("Where you played") {
                    if analytics.isDirectionConfident {
                        row("Attacking third", percent(thirds.attacking))
                        row("Middle third", percent(thirds.middle))
                        row("Defensive third", percent(thirds.defensive))
                    } else {
                        row("Middle third", percent(thirds.middle))
                        row("Either end", percent(thirds.attacking + thirds.defensive),
                            note: "Say which way you attacked in Edit Match to split this")
                    }
                }
            }
            if let average = analytics.averageHeartRate {
                Section("Heart rate") {
                    row("Average", "\(Int(average)) bpm")
                    if let maximum = analytics.maximumHeartRate { row("Highest", "\(Int(maximum)) bpm") }
                }
            }
            if !analytics.metersPerMinute.isEmpty {
                Section("Ground covered each minute") {
                    Chart(Array(analytics.metersPerMinute.enumerated()), id: \.offset) { minute, meters in
                        BarMark(x: .value("Minute", minute + 1),
                                y: .value("Distance", UnitSystem.current == .imperial ? meters * 1.0936 : meters))
                            .foregroundStyle(.green)
                    }
                    .chartYAxisLabel(UnitSystem.current.shortDistance(0).unit)
                    .frame(height: 180)
                    .padding(.vertical, 8)
                }
            }
        }
        .navigationTitle("All Numbers")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func percent(_ share: Double) -> String { share.formatted(.percent.precision(.fractionLength(0))) }

    private func row(_ title: String, _ measure: UnitSystem.Measure, note: String? = nil) -> some View {
        row(title, measure.text, note: note).accessibilityValue(measure.spoken)
    }

    private func row(_ title: String, _ value: String, note: String? = nil) -> some View {
        LabeledContent {
            Text(value).monospacedDigit().foregroundStyle(.primary)
        } label: {
            Text(title)
            if let note { Text(note) }
        }
    }
}
