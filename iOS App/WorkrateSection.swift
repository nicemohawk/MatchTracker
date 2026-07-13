// WorkrateSection.swift
// MatchTracker

import SwiftUI
import Charts
import MatchTrackerKit

struct WorkrateSection: View {
    @ObservedObject var detail: MatchDetailModel
    let analytics: MatchAnalytics

    private var report: WorkrateReport { analytics.workrate }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            workrateGauge
            distancePerMinuteChart
            speedZoneDonut
            if !detail.heartRateSeries.isEmpty {
                heartRateChart
            }
        }
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
