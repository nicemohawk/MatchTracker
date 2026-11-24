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
                        MomentRow(event: event, minute: detail.minute(of: event),
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
    let minute: Int
    var onPlay: (() -> Void)?

    var body: some View {
        HStack(spacing: 14) {
            Text("\(minute)′")
                .font(.system(.body, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
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
            Spacer(minLength: 0)
            if let onPlay {
                Button("Play Video", systemImage: "play.circle.fill", action: onPlay)
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .frame(width: 44, height: 44)
            }
        }
        .frame(minHeight: 48)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Minute \(minute), \([event.kind.momentTitle, event.note ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))")
        .accessibilityActions {
            if let onPlay { Button("Play Video", action: onPlay) }
        }
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Best runs").font(.title2.bold())
            VStack(spacing: 0) {
                ForEach(runs) { run in
                    let speed = UnitSystem.current.speed(run.peakSpeed)
                    let distance = UnitSystem.current.shortDistance(run.distanceMeters)
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                        : AnyLayout(HStackLayout(spacing: 14))
                    layout {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(run.title).font(.body)
                            Text(["\(Int(run.fromT / 60) + 1)′", run.detail].compactMap { $0 }.joined(separator: " · "))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                        VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
                            Text(speed.text)
                                .font(.system(.title3, design: .rounded, weight: .semibold))
                                .monospacedDigit()
                            Text(distance.text).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 6 : 0)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(run.title), \(speed.spoken) over \(distance.spoken), minute \(Int(run.fromT / 60) + 1)")
                }
            }
        }
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
            EffortVerdict(workout: detail.workout, measured: Self.word(for: detail.digest?.effort))
            if !detail.heartRateSeries.isEmpty {
                HeartRateChart(series: detail.heartRateSeries, start: detail.matchStart, halftime: analytics.halftime)
                    .frame(height: 180)
            }
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

    private struct Point: Identifiable {
        let id: Int
        let minute: Double
        let bpm: Double
    }

    /// One point a minute: enough shape, and it draws instantly.
    private var points: [Point] {
        let byMinute = Dictionary(grouping: series) { Int($0.date.timeIntervalSince(start) / 60) }
        return byMinute.keys.filter { $0 >= 0 }.sorted().map { minute in
            let samples = byMinute[minute] ?? []
            let total = samples.reduce(0.0) { $0 + $1.bpm }
            return Point(id: minute, minute: Double(minute), bpm: total / Double(max(samples.count, 1)))
        }
    }

    var body: some View {
        let points = points
        let selected = selectedMinute.flatMap { minute in
            points.min { abs($0.minute - minute) < abs($1.minute - minute) }
        }
        Chart {
            if let halftime { halftimeBand(halftime) }
            ForEach(points) { line($0) }
            if let selected { callout(selected) }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXSelection(value: $selectedMinute)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisValueLabel { if let minute = value.as(Double.self) { Text("\(Int(minute))′") } }
            }
        }
        .accessibilityLabel("Heart rate through the match")
    }

    private func halftimeBand(_ halftime: DateInterval) -> some ChartContent {
        let from = halftime.start.timeIntervalSince(start) / 60
        let to = halftime.end.timeIntervalSince(start) / 60
        return RectangleMark(xStart: .value("Half-time start", from), xEnd: .value("Half-time end", to))
            .foregroundStyle(Color(.systemGray5))
            .accessibilityLabel("Half-time")
    }

    private func line(_ point: Point) -> some ChartContent {
        LineMark(x: .value("Minute", point.minute), y: .value("Heart rate", point.bpm))
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
