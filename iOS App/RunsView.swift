// RunsView.swift
// MatchTracker
//
// What the runs were: each one to pick out on the pitch, and what they add up to.

import Charts
import MatchTrackerKit
import SwiftUI

extension MatchRun.Heading {
    var title: String {
        switch self {
        case .forward: return "Forward"
        case .back: return "Back"
        case .across: return "Across"
        }
    }

    /// Never told apart by color alone.
    var symbol: String {
        switch self {
        case .forward: return "arrow.up"
        case .back: return "arrow.down"
        case .across: return "arrow.left.and.right"
        }
    }

    var color: Color {
        switch self {
        case .forward: return Theme.turf
        case .back: return .primary
        case .across: return Theme.secondaryLabel.opacity(0.7)
        }
    }

    /// On cloth, whatever the scheme.
    var yarn: KitColors.RGB {
        let kit = KitColors.current
        switch self {
        case .forward: return kit.yarns[2]
        case .back: return KitColors.ivory
        case .across: return KitColors.RGB(0.70, 0.74, 0.69)
        }
    }
}

extension MatchRun {
    var color: Color { heading?.color ?? Theme.turf }

    /// "14.9 mph over 32 yd in 4 seconds".
    var spoken: String {
        let units = UnitSystem.current
        return "\(units.speed(peakSpeed).spoken) over \(units.shortDistance(distanceMeters).spoken) in \(duration.formatted(.number.precision(.fractionLength(0)))) seconds"
    }
}

// MARK: - Under the pitch

/// Every run along the match, as tall as it was fast. Dragging picks them out one by one.
struct RunStrip: View {
    let clock: StageClock
    let analytics: MatchAnalytics
    let events: [MatchEvent]

    @State private var selectedMinute: Double?
    @ScaledMetric(relativeTo: .footnote) private var headroom = 20.0

    private var runs: [MatchRun] { analytics.matchRuns }
    private var minutes: MatchMinutes { MatchMinutes(kickoff: analytics.interval.start, halftime: analytics.halftime) }

    private func minute(of date: Date) -> Double { minutes.playedSeconds(at: date) / 60 }
    private func speed(_ meters: Double) -> Double { UnitSystem.current == .imperial ? meters * 2.23694 : meters * 3.6 }

    var body: some View {
        let top = speed(max(runs.map(\.peakSpeed).max() ?? 0, SpeedThresholds.sprinting)) * 1.08
        let goals = events.filter { [.goalMine, .assist].contains($0.kind) && analytics.interval.contains($0.date) }
        Chart {
            ForEach(runs) { run in
                BarMark(x: .value("Minute", minute(of: run.segment.interval.start)),
                        y: .value("Top speed", speed(run.peakSpeed)), width: .fixed(clock.spotlight == run.id ? 8 : 5))
                    .clipShape(.rect(cornerRadius: 2))
                    .foregroundStyle(run.color)
                    .opacity(clock.spotlight == nil || clock.spotlight == run.id ? 1 : 0.35)
                    .accessibilityLabel(minutes.spoken(for: run.segment.interval.start))
                    .accessibilityValue([run.title, run.spoken, run.story].compactMap { $0 }.joined(separator: ", "))
            }
            RuleMark(y: .value("Sprint", speed(SpeedThresholds.sprinting)))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(.secondary.opacity(0.6))
                .annotation(position: .top, alignment: .trailing, spacing: 1) {
                    Text("Sprint").font(.footnote).foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
            if let halftime = analytics.halftime {
                RuleMark(x: .value("Half-time", minute(of: halftime.start)))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .annotation(position: .top, spacing: 2) { Text("HT").font(.footnote).foregroundStyle(.secondary) }
                    .accessibilityHidden(true)
            }
            ForEach(goals) { goal in
                RuleMark(x: .value("Moment", minute(of: goal.date)))
                    .foregroundStyle(Theme.turf.opacity(0.35))
                    .annotation(position: .top, spacing: 2) {
                        Image(systemName: goal.kind == .goalMine ? "soccerball" : "hand.thumbsup.fill")
                            .font(.footnote)
                            .foregroundStyle(Theme.turf)
                    }
                    .accessibilityHidden(true)
            }
        }
        .chartXScale(domain: 0...max(minute(of: analytics.interval.end), 1))
        .chartYScale(domain: 0...top)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                if let minute = value.as(Double.self) { AxisValueLabel("\(Int(minute))′") }
            }
        }
        .chartXSelection(value: $selectedMinute)
        .padding(.top, headroom)
        .frame(height: 130 + headroom)
        .onChange(of: selectedMinute) { _, minute in
            guard let minute, let nearest = runs.min(by: { distance($0, minute) < distance($1, minute) }),
                  nearest.id != clock.spotlight else { return }
            clock.pick(nearest.id)
        }
    }

    private func distance(_ run: MatchRun, _ minute: Double) -> Double { abs(self.minute(of: run.segment.interval.start) - minute) }
}

/// The run picked out, or what they all come to.
struct RunDetailCard: View {
    let clock: StageClock
    let analytics: MatchAnalytics
    let report: RunReport
    /// Told whether the wearer attacked up the screen. Nil when it's known, or telling wouldn't help.
    let onDirection: ((Bool) -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var runs: [MatchRun] { analytics.matchRuns }
    private var minutes: MatchMinutes { MatchMinutes(kickoff: analytics.interval.start, halftime: analytics.halftime) }
    private var index: Int? { runs.firstIndex { $0.id == clock.spotlight } }

    var body: some View {
        if let index {
            picked(runs[index], at: index)
        } else {
            everything
        }
    }

    private var everything: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(runs.count) runs, \(report.sprints == 1 ? "1 sprint" : "\(report.sprints) sprints")").font(.headline)
            if report.knowsHeadings {
                let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                                                                 : AnyLayout(HStackLayout(spacing: 18))
                layout {
                    ForEach(MatchRun.Heading.allCases, id: \.self) { heading in
                        Label("\(heading.title) \(report.count(heading))", systemImage: heading.symbol)
                            .foregroundStyle(heading.color)
                    }
                }
                .font(.subheadline.weight(.semibold))
            }
            Text("Drag along the chart, or tap a run, to look at one.").font(.footnote).foregroundStyle(.secondary)
            if let onDirection {
                VStack(alignment: .leading, spacing: 8) {
                    Text(analytics.halftime == nil ? "Were you attacking up the screen?" : "Did you attack up the screen in the first half?")
                        .font(.headline)
                    Text("Then your runs can be told apart: forward, back and across.").font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button { onDirection(true) } label: { Label("Up", systemImage: "arrow.up").frame(maxWidth: .infinity) }
                        Button { onDirection(false) } label: { Label("Down", systemImage: "arrow.down").frame(maxWidth: .infinity) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func picked(_ run: MatchRun, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(minutes.text(for: run.segment.interval.start)).font(.name(.title3)).foregroundStyle(.tint)
                Text(run.title ?? (run.isSprint ? "Sprint" : "Run")).font(.name(.title3)).lineLimit(2).minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Text("\(index + 1) of \(runs.count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 24) { figures(run) }
                VStack(alignment: .leading, spacing: 6) { figures(run) }
            }
            if let story = run.story {
                Label(story, systemImage: run.heading?.symbol ?? "figure.run")
                    .font(.body)
            }
            if let gap = run.gapBefore {
                Text("\(RunReport.spoken(gap)) since the last").font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button { clock.pick(runs[index - 1].id) } label: {
                    Label("Earlier", systemImage: "chevron.backward").labelStyle(.iconOnly).frame(minWidth: 28, minHeight: 28)
                }
                .disabled(index == 0)
                Button { clock.pick(runs[index + 1].id) } label: {
                    Label("Later", systemImage: "chevron.forward").labelStyle(.iconOnly).frame(minWidth: 28, minHeight: 28)
                }
                .disabled(index == runs.count - 1)
                Spacer()
                Button("All Runs") { clock.pick(nil) }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func figures(_ run: MatchRun) -> some View {
        let units = UnitSystem.current
        figure(units.speed(run.peakSpeed), "Top speed")
        figure(units.shortDistance(run.distanceMeters), "Distance")
        VStack(alignment: .leading, spacing: 0) {
            (Text(run.duration.formatted(.number.precision(.fractionLength(0)))).font(.figure(.title)) + Text(" sec").font(.subheadline))
            Text("Lasted").font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func figure(_ measure: UnitSystem.Measure, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            (Text(measure.value).font(.figure(.title)) + Text(" \(measure.unit)").font(.subheadline))
            Text(label).font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(measure.spoken)")
    }
}

// MARK: - Chapter

/// The runs in numbers, against what's usual, and the ones worth seeing.
struct RunsChapter: View {
    let analytics: MatchAnalytics
    let report: RunReport
    let minutes: MatchMinutes
    /// How many the player would usually have made in the time they played.
    let usual: Double?
    /// Shows a run on the pitch.
    let onShow: (MatchRun) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Runs").font(.name(.title3))
            if let headline = report.headline { Text(headline) }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) { numbers.frame(maxWidth: .infinity, alignment: .leading) }
                VStack(alignment: .leading, spacing: 12) { numbers }
            }
            if let halves = report.halves { HalvesBars(first: halves.first, second: halves.second) }
            if let busiest = report.busiest {
                LabeledContent("Busiest spell") {
                    Text("\(minutes.text(for: busiest.start))–\(minutes.text(for: busiest.end)), \(busiest.count) runs").foregroundStyle(.primary)
                }
            }
            VStack(spacing: 0) {
                ForEach(report.runs.filter { $0.title != nil }) { run in
                    Button { onShow(run) } label: { RunRow(run: run, minutes: minutes, fastest: nil) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows it on the pitch")
                }
                NavigationLink {
                    AllRunsView(report: report, minutes: minutes, onShow: onShow)
                } label: {
                    HStack {
                        Text("All \(report.runs.count) runs")
                        Spacer()
                        Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var numbers: some View {
        number("\(report.runs.count)", "Runs", note: usual.map { "Usually \(Int($0.rounded()))" })
        number("\(report.sprints)", "Sprints", note: nil)
        if let gap = report.typicalGap { number(RunReport.spoken(gap), "Between runs", note: nil) }
    }

    private func number(_ value: String, _ label: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(.largeTitle, weight: .heavy).width(.compressed)).monospacedDigit()
            Text(label).font(.subheadline).foregroundStyle(Theme.secondaryLabel)
            if let note { Text(note).font(.subheadline).foregroundStyle(Theme.secondaryLabel) }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// Runs an hour of play in each half, so half a half on the bench doesn't look like fading.
private struct HalvesBars: View {
    let first: Double
    let second: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Runs an hour").font(.subheadline).foregroundStyle(Theme.secondaryLabel)
            bar("First half", first)
            bar("Second half", second)
        }
    }

    private func bar(_ title: String, _ rate: Double) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.subheadline).frame(minWidth: 92, alignment: .leading).fixedSize()
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.turf)
                    .frame(width: max(proxy.size.width * rate / max(first, second, 0.01), 2))
            }
            .frame(height: 14)
            Text("\(Int(rate.rounded()))").font(.figure(.body)).monospacedDigit().frame(minWidth: 28, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(Int(rate.rounded())) runs an hour")
    }
}

private struct RunRow: View {
    let run: MatchRun
    let minutes: MatchMinutes
    /// Draws a bar against this, when there's a list to compare with.
    let fastest: Double?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let isLarge = dynamicTypeSize.isAccessibilitySize
        let layout = isLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 12))
        return VStack(alignment: .leading, spacing: 6) {
            layout {
                HStack(spacing: 12) {
                    Text(minutes.text(for: run.segment.interval.start))
                        .font(.figure(.body))
                        .monospacedDigit()
                        .foregroundStyle(.tint)
                        .frame(minWidth: 36, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(run.title ?? run.story ?? (run.isSprint ? "Sprint" : "Run")).font(.body)
                        if let detail = run.title == nil ? run.gapBefore.map({ "\(RunReport.spoken($0)) since the last" }) : run.story {
                            Text(detail).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                if !isLarge { Spacer(minLength: 8) }
                VStack(alignment: isLarge ? .leading : .trailing, spacing: 2) {
                    Text(UnitSystem.current.speed(run.peakSpeed).text).font(.figure(.title3)).monospacedDigit()
                    Text("\(UnitSystem.current.shortDistance(run.distanceMeters).text) · \(Int(run.duration.rounded())) sec")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if let fastest, fastest > 0 {
                ProgressView(value: min(run.peakSpeed / fastest, 1)).tint(run.color).accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([minutes.spoken(for: run.segment.interval.start), run.title ?? (run.isSprint ? "Sprint" : "Run")].joined(separator: ", "))
        .accessibilityValue([run.spoken, run.story].compactMap { $0 }.joined(separator: ", "))
    }
}

/// Every run, however it's wanted.
private struct AllRunsView: View {
    let report: RunReport
    let minutes: MatchMinutes
    let onShow: (MatchRun) -> Void

    private enum Order: String, CaseIterable, Identifiable {
        case time = "Time", speed = "Speed", distance = "Distance"
        var id: Self { self }
    }

    @State private var order = Order.time
    @Environment(\.dismiss) private var dismiss

    private var sorted: [MatchRun] {
        switch order {
        case .time: return report.runs
        case .speed: return report.runs.sorted { $0.peakSpeed > $1.peakSpeed }
        case .distance: return report.runs.sorted { $0.distanceMeters > $1.distanceMeters }
        }
    }

    var body: some View {
        let fastest = report.runs.map(\.peakSpeed).max()
        List {
            Section {
                ForEach(sorted) { run in
                    Button {
                        dismiss()
                        onShow(run)
                    } label: {
                        RunRow(run: run, minutes: minutes, fastest: fastest)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows it on the pitch")
                }
            } header: {
                Picker("Sort by", selection: $order) {
                    ForEach(Order.allCases) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .textCase(nil)
                .padding(.bottom, 8)
            }
            .listRowBackground(Theme.surface)
        }
        .canvasBackground()
        .navigationTitle("Runs")
        .navigationBarTitleDisplayMode(.inline)
    }
}
