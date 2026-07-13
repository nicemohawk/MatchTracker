// WorkrateSection.swift
// MatchTracker

import SwiftUI
import Charts
import MatchTrackerKit

struct WorkrateSection: View {
    @ObservedObject var detail: MatchDetailModel
    let analytics: MatchAnalytics
    @Environment(TrainingLoadService.self) private var trainingLoad

    private var report: WorkrateReport { analytics.workrate }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            workrateGauge
            trainingLoadContext
            fatigueBuckets
            distancePerMinuteChart
            speedZoneDonut
            if !detail.heartRateSeries.isEmpty {
                heartRateChart
            }
        }
    }

    // MARK: Training-load context

    /// Reads this match against the player's 4-week trend (HealthKit load + cached workrates).
    @ViewBuilder
    private var trainingLoadContext: some View {
        if let load = trainingLoad.fourWeekLoad {
            VStack(alignment: .leading, spacing: 3) {
                if let average = load.averageWorkrateScore {
                    let delta = report.workrateScore - average
                    Label(
                        delta >= 0
                            ? "Above your 4-week average (\(Int(average))) by \(Int(delta))"
                            : "Below your 4-week average (\(Int(average))) by \(Int(-delta))",
                        systemImage: delta >= 0 ? "arrow.up.right" : "arrow.down.right"
                    )
                    .font(.caption)
                    .foregroundStyle(delta >= 0 ? .green : .orange)
                }
                HStack(spacing: 10) {
                    Text("\(load.workoutCount) matches in 4 weeks")
                    if let vo2 = trainingLoad.vo2Max {
                        Text(String(format: "VO₂max %.1f", vo2))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Fatigue buckets

    /// Workrate output per 15-minute block, surfacing second-half drop-off. Uses the
    /// per-minute distances already computed for on-pitch time.
    @ViewBuilder
    private var fatigueBuckets: some View {
        let buckets = fifteenMinuteBuckets
        if buckets.count >= 2 {
            VStack(alignment: .leading, spacing: 6) {
                Text("Output by 15-Minute Block").font(.headline)
                Chart(Array(buckets.enumerated()), id: \.offset) { index, metersPerMinute in
                    BarMark(
                        x: .value("Block", blockLabel(index)),
                        y: .value("m/min", metersPerMinute)
                    )
                    .foregroundStyle(bucketColor(metersPerMinute, first: buckets[0]))
                    .cornerRadius(3)
                    .annotation(position: .top) {
                        if index > 0, buckets[0] > 0 {
                            let change = Int(((metersPerMinute - buckets[0]) / buckets[0]) * 100)
                            Text(change <= 0 ? "\(change)%" : "+\(change)%")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .chartYAxisLabel("m/min")
                .frame(height: 140)
                Text("Change vs first block — a steady drop suggests fatigue.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var fifteenMinuteBuckets: [Double] {
        let perMinute = report.distancePerMinute
        guard perMinute.count >= 15 else { return [] }
        return stride(from: 0, to: perMinute.count, by: 15).compactMap { start in
            let block = Array(perMinute[start..<min(start + 15, perMinute.count)])
            guard block.count >= 5 else { return nil }   // ignore tiny trailing slivers
            return block.reduce(0, +) / Double(block.count)
        }
    }

    private func blockLabel(_ index: Int) -> String {
        "\(index * 15)–\(index * 15 + 15)'"
    }

    private func bucketColor(_ value: Double, first: Double) -> Color {
        guard first > 0 else { return .green }
        let ratio = value / first
        if ratio >= 0.9 { return .green }
        if ratio >= 0.75 { return .orange }
        return .red
    }

    // MARK: Gauge

    private var workrateGauge: some View {
        HStack(spacing: 16) {
            Gauge(value: report.workrateScore, in: 0...100) {
                Text("Workrate")
            } currentValueLabel: {
                Text("\(Int(report.workrateScore))")
            }
            .gaugeStyle(.accessoryCircular)
            .tint(Gradient(colors: [.blue, .green, .orange, .red]))
            .scaleEffect(1.3)
            .frame(width: 90, height: 90)

            VStack(alignment: .leading, spacing: 4) {
                Text("Workrate Score").font(.headline)
                Text("Composite of distance rate, sprint frequency, and high-intensity share.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Text("\(report.runCount) runs").font(.caption).foregroundStyle(.secondary)
                    Text("\(report.sprintCount) sprints").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Distance per minute

    private var distancePerMinuteChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Distance per Minute").font(.headline)
            Chart(Array(report.distancePerMinute.enumerated()), id: \.offset) { index, meters in
                BarMark(
                    x: .value("Minute", index),
                    y: .value("Meters", meters)
                )
                .foregroundStyle(barShading(for: meters))
                .cornerRadius(2)
            }
            .chartXAxisLabel("Minute on pitch")
            .chartYAxisLabel("m")
            .frame(height: 160)
            .overlay {
                if report.distancePerMinute.isEmpty {
                    Text("No per-minute data").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func barShading(for meters: Double) -> LinearGradient {
        // On-pitch high-output minutes shade warmer.
        let intensity = min(1, meters / 180)
        return LinearGradient(
            colors: [.green.opacity(0.5), Color(red: 0.9, green: 0.4 * (1 - intensity), blue: 0.1)],
            startPoint: .bottom, endPoint: .top
        )
    }

    // MARK: Speed zones donut

    private var speedZoneDonut: some View {
        let zones = speedZoneData
        return VStack(alignment: .leading, spacing: 6) {
            Text("Speed Zones").font(.headline)
            HStack(alignment: .center, spacing: 16) {
                Chart(zones, id: \.name) { zone in
                    SectorMark(
                        angle: .value("Seconds", zone.seconds),
                        innerRadius: .ratio(0.6),
                        angularInset: 1.5
                    )
                    .foregroundStyle(zone.color)
                }
                .frame(width: 150, height: 150)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(zones, id: \.name) { zone in
                        HStack(spacing: 8) {
                            Circle().fill(zone.color).frame(width: 9, height: 9)
                            Text(zone.name).font(.caption)
                            Spacer()
                            Text(MatchFormat.duration(zone.seconds)).font(.caption).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private struct Zone { let name: String; let seconds: Double; let color: Color }

    private var speedZoneData: [Zone] {
        let z = report.speedZones
        return [
            Zone(name: "Standing", seconds: z.standing, color: .gray),
            Zone(name: "Walking", seconds: z.walking, color: .blue),
            Zone(name: "Jogging", seconds: z.jogging, color: .green),
            Zone(name: "Running", seconds: z.running, color: .orange),
            Zone(name: "Sprinting", seconds: z.sprinting, color: .red)
        ].filter { $0.seconds > 0 }
    }

    // MARK: Heart rate line

    private var heartRateChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Heart Rate").font(.headline)
            Chart(Array(detail.heartRateSeries.enumerated()), id: \.offset) { _, sample in
                LineMark(
                    x: .value("Time", sample.date),
                    y: .value("BPM", sample.bpm)
                )
                .foregroundStyle(.red)
                .interpolationMethod(.catmullRom)
            }
            .chartYAxisLabel("bpm")
            .frame(height: 140)
        }
    }
}
