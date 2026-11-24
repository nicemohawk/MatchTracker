// StintsView.swift
// MatchTracker

import Charts
import MatchTrackerKit
import SwiftUI

/// A match without a pitch to draw: the heart, and when it was playing.
struct StintsHero: View {
    let stints: Stints
    /// What counted as playing, once the wearer's own subs are taken into account.
    let playing: [DateInterval]
    let series: [(date: Date, bpm: Double)]
    let interval: DateInterval

    private struct Point: Identifiable {
        let id: Int
        let minute: Double
        let bpm: Double
    }

    /// One point every twenty seconds: enough to see a shift change.
    private var points: [Point] {
        Dictionary(grouping: series.filter { interval.contains($0.date) }) {
            Int($0.date.timeIntervalSince(interval.start) / 20)
        }
        .map { key, samples in
            Point(id: key, minute: (Double(key) + 0.5) / 3, bpm: samples.reduce(0) { $0 + $1.bpm } / Double(samples.count))
        }
        .sorted { $0.id < $1.id }
    }

    private func minute(_ date: Date) -> Double { date.timeIntervalSince(interval.start) / 60 }

    var body: some View {
        let points = points
        let lowest = ((points.map(\.bpm).min() ?? 60) / 20).rounded(.down) * 20
        let highest = max(((points.map(\.bpm).max() ?? 180) / 20).rounded(.up) * 20, lowest + 20)
        Chart {
            ForEach(playing, id: \.start) { stint in
                RectangleMark(xStart: .value("On", minute(stint.start)), xEnd: .value("Off", minute(stint.end)),
                              yStart: .value("Bottom", lowest), yEnd: .value("Top", highest))
                    .foregroundStyle(Theme.turf.opacity(0.28))
                    .cornerRadius(6)
                    .accessibilityLabel("Playing")
                    .accessibilityValue("From minute \(Int(minute(stint.start)) + 1) for \(Int((stint.duration / 60).rounded())) minutes")
            }
            ForEach(points) { point in
                LineMark(x: .value("Minute", point.minute), y: .value("Heart rate", point.bpm))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .foregroundStyle(Color.pink)
            }
            .accessibilityHidden(true)
        }
        .chartYScale(domain: lowest...highest)
        .chartXScale(domain: 0...(interval.duration / 60))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisValueLabel { if let minute = value.as(Double.self) { Text("\(Int(minute))′") } }
            }
        }
        .accessibilityLabel("Playing and resting, with your heart rate")
    }
}

/// Subs roll, games stack up: how the session broke down.
struct StintsChapter: View {
    let stints: Stints
    let playing: [DateInterval]
    /// As the wearer settled them.
    let games: [GameResult]?

    private var longest: TimeInterval { playing.map(\.duration).max() ?? stints.longest }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Stints").font(.title2.bold())
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 16) { numbers(stretching: true) }
                VStack(alignment: .leading, spacing: 12) { numbers(stretching: false) }
            }
            if !rows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(rows, id: \.start) { row in
                        LabeledContent(row.start.formatted(date: .omitted, time: .shortened)) {
                            Text(row.text).monospacedDigit()
                        }
                        .frame(minHeight: 44)
                    }
                }
            }
        }
    }

    /// Each game once somebody has said there were several. Until then just when the playing was:
    /// two blocks may be two games or two halves.
    private var rows: [(start: Date, text: String)] {
        if let games {
            return games.map { game in
                let length = "\(minutes(game.end.timeIntervalSince(game.start))) min"
                guard let outcome = game.outcome ?? game.score?.outcome else { return (game.start, length) }
                return (game.start, "\(length), \(outcome == .won ? "won" : outcome == .lost ? "lost" : "drew")")
            }
        }
        guard stints.games.count > 1 else { return [] }
        return stints.games.compactMap { block in
            block.first.map { ($0.start, "\(minutes(block.reduce(0) { $0 + $1.duration })) min") }
        }
    }

    @ViewBuilder
    private func numbers(stretching: Bool) -> some View {
        number("\(playing.count)", nil, "Stints", stretching)
        number("\(minutes(longest))", "min", "Longest", stretching)
        if let recovery = stints.recovery { number("\(Int(recovery))", "bpm", "Recovery in a minute", stretching) }
    }

    private func number(_ value: String, _ unit: String?, _ label: String, _ stretching: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(.title, design: .rounded, weight: .semibold)).monospacedDigit()
                if let unit { Text(unit).font(.subheadline.weight(.medium)).foregroundStyle(.secondary) }
            }
            Text(label).font(.subheadline).foregroundStyle(.secondary)
        }
        .fixedSize()
        .frame(maxWidth: stretching ? .infinity : nil, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func minutes(_ seconds: TimeInterval) -> Int { Int((seconds / 60).rounded()) }
}
