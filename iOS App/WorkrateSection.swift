// WorkrateSection.swift
// MatchTracker

import SwiftUI
import Charts
import MatchTrackerKit

struct WorkrateSection: View {
    @ObservedObject var detail: MatchDetailModel
    let analytics: MatchAnalytics
    @Environment(TrainingLoadService.self) private var trainingLoad
    @EnvironmentObject private var store: MatchStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One-time entrance flag for the Match Load tiles — flips true on first appear so the
    /// values roll up from zero (or snap under Reduce Motion), matching the hero ring's count-up.
    @State private var loadRevealed = false

    private var report: WorkrateReport { analytics.workrate }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            workrateSummary
            trainingLoadContext
            componentBreakdown
            effortSourceCaption
            matchLoadGrid
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
            // Compute the workrate average live from the cache at render time — at launch the
            // detail cache is still empty, so a snapshot taken during bootstrap is always nil.
            let average = store.recentAverageWorkrate(days: 28, excluding: detail.matchIdentifier)
            VStack(alignment: .leading, spacing: 3) {
                if let average {
                    let delta = report.workrateScore - average
                    Label(
                        delta >= 0
                            ? "Above your 4-week average (\(Int(average))) by \(Int(delta))"
                            : "Below your 4-week average (\(Int(average))) by \(Int(-delta))",
                        systemImage: delta >= 0 ? "arrow.up.right" : "arrow.down.right"
                    )
                    .font(.caption)
                    .foregroundStyle(delta >= 0 ? Theme.turf : Theme.bench)
                }
                HStack(spacing: 10) {
                    Text("\(load.workoutCount) matches in 4 weeks")
                    if let vo2 = trainingLoad.vo2Max {
                        Text(String(format: "VO₂max %.1f", vo2))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                acuteChronicContext
            }
        }
    }

    /// Acute:chronic workload ratio — the last 7 days of workrate against the rolling 28-day norm,
    /// the standard flag for spotting under-load or an injury-risky spike. Derived from our own
    /// stored workrate history (HealthKit has no per-sport ACWR). Below four analyzed matches the
    /// windows are too thin to trust, so we show a quiet placeholder rather than a fabricated ratio.
    @ViewBuilder
    private var acuteChronicContext: some View {
        let recentMatchCount = store.matches.filter { $0.startDate >= chronicCutoff }.count
        if recentMatchCount < 4 {
            Label("Load balance builds after a few more matches", systemImage: "chart.line.uptrend.xyaxis")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if let acwr = TrainingLoadService.acuteChronic(
            acute: store.recentAverageWorkrate(days: 7, excluding: detail.matchIdentifier),
            chronic: store.recentAverageWorkrate(days: 28, excluding: detail.matchIdentifier)
        ) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("7d : 28d load")
                        .captionLabel()
                    Text(String(format: "%.2f", acwr.ratio))
                        .font(.caption).monospacedDigit().foregroundStyle(.primary)
                    Text(acwr.status.word)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(acwr.status.tint)
                }
                Text("Acute:chronic ratio — 0.8–1.3 is balanced; higher climbs into elevated-load territory.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var chronicCutoff: Date {
        Calendar.current.date(byAdding: .day, value: -28, to: Date()) ?? Date()
    }

    /// Quiet breakdown of the 0–100 sub-scores behind the hero ring — one subtle horizontal bar
    /// per contributing signal, in the component's semantic tint. Renders only the signals that
    /// actually fed the score (GPS-only omits heart rate; indoor shows heart rate alone).
    @ViewBuilder
    private var componentBreakdown: some View {
        let rows = componentRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows, id: \.name) { row in
                    HStack(spacing: 10) {
                        Text(row.name).captionLabel()
                            .frame(width: 84, alignment: .leading)
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(row.tint.opacity(0.15))
                                Capsule().fill(row.tint.opacity(0.85))
                                    .frame(width: max(2, geometry.size.width * min(1, row.value / 100)))
                            }
                        }
                        .frame(height: 6)
                        Text("\(Int(row.value.rounded()))")
                            .font(.caption2).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)
                    }
                }
                if report.isLowConfidence == true {
                    Text("Low confidence — short stint")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private struct ComponentRow { let name: String; let value: Double; let tint: Color }

    private var componentRows: [ComponentRow] {
        guard let components = report.components else { return [] }
        var rows: [ComponentRow] = []
        if let value = components.distanceRate { rows.append(ComponentRow(name: "Distance", value: value, tint: Theme.pace)) }
        if let value = components.highIntensity { rows.append(ComponentRow(name: "Intensity", value: value, tint: Theme.turf)) }
        if let value = components.sprints { rows.append(ComponentRow(name: "Sprints", value: value, tint: Theme.sprint)) }
        if let value = components.heartRate { rows.append(ComponentRow(name: "Heart Rate", value: value, tint: Theme.heart)) }
        return rows
    }

    /// Which signals fed the workrate score, as a quiet caption under the training-load context.
    @ViewBuilder
    private var effortSourceCaption: some View {
        if let text = effortSourceText {
            Label(text, systemImage: "waveform.path.ecg")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var effortSourceText: String? {
        switch report.effortSource {
        case "gps+hr": return "Effort from GPS + heart rate"
        case "gps": return "Effort from GPS"
        case "hr": return "Effort from heart rate"
        default: return nil
        }
    }

    // MARK: Match Load

    /// Industry-standard soccer load metrics (sprint distance, HSR, accel/decel counts,
    /// distance-per-minute, top speed) in a six-tile grid so our numbers speak the same language
    /// coaches read on STATSports/Catapult. GPS-only — nil for indoor / HR-only sessions.
    @ViewBuilder
    private var matchLoadGrid: some View {
        if let load = analytics.loadMetrics {
            VStack(alignment: .leading, spacing: 10) {
                Text("Match Load").sectionHeading()
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                    spacing: 10
                ) {
                    LoadTile(label: "Sprint Dist", target: load.sprintDistanceMeters / 1000,
                             unit: "km", decimals: 2, tint: Theme.sprint,
                             revealed: loadRevealed, animation: countUpAnimation)
                    LoadTile(label: "High-Speed Run", target: load.highSpeedRunningMeters / 1000,
                             unit: "km", decimals: 2, tint: Theme.sprint,
                             revealed: loadRevealed, animation: countUpAnimation)
                    LoadTile(label: "Accels", target: Double(load.accelerationCount),
                             unit: "count", decimals: 0, tint: Theme.sprint,
                             revealed: loadRevealed, animation: countUpAnimation)
                    LoadTile(label: "Decels", target: Double(load.decelerationCount),
                             unit: "count", decimals: 0, tint: Theme.sprint,
                             revealed: loadRevealed, animation: countUpAnimation)
                    LoadTile(label: "Dist/Min", target: load.distancePerMinuteMeters,
                             unit: "m/min", decimals: 0, tint: Theme.pace,
                             revealed: loadRevealed, animation: countUpAnimation)
                    LoadTile(label: "Top Speed", target: load.topSpeedMetersPerSecond * 3.6,
                             unit: "km/h", decimals: 1, tint: Theme.turf,
                             revealed: loadRevealed, animation: countUpAnimation)
                }
                Text("Industry-standard bands: HSR 19.8–25.2 km/h · sprint >25.2 km/h")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .onAppear {
                guard !loadRevealed else { return }
                if let countUpAnimation {
                    withAnimation(countUpAnimation) { loadRevealed = true }
                } else {
                    loadRevealed = true
                }
            }
        }
    }

    /// Count-up ease for the load tiles — nil under Reduce Motion so values snap to final.
    private var countUpAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.9)
    }

    /// One load metric on a tinted metric tile: a monospaced-digit numeral that rolls up from zero
    /// via `numericText`, a unit line, and an uppercase label — the app's mini-stat idiom.
    private struct LoadTile: View {
        let label: String
        let target: Double
        let unit: String
        let decimals: Int
        let tint: Color
        let revealed: Bool
        let animation: Animation?

        private var shownValue: Double { revealed ? target : 0 }

        var body: some View {
            VStack(spacing: 4) {
                Text(shownValue, format: .number.precision(.fractionLength(decimals)))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .contentTransition(.numericText(value: shownValue))
                    .animation(animation, value: revealed)
                Text(unit).font(.caption2).foregroundStyle(.secondary)
                Text(label).captionLabel()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .metricTile(tint: tint)
        }
    }

    // MARK: Fatigue buckets

    /// Workrate output per 15-minute block, surfacing second-half drop-off. Uses the
    /// per-minute distances already computed for on-pitch time.
    @ViewBuilder
    private var fatigueBuckets: some View {
        let buckets = fifteenMinuteBuckets
        if buckets.count >= 2 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Output by 15-Minute Block").sectionHeading()
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
                .frame(height: 150)
                .fullBleed()
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

    /// Single-hue (turf) ramp: darker/lower-opacity blocks read as fatigue without a hue jump.
    private func bucketColor(_ value: Double, first: Double) -> Color {
        guard first > 0 else { return Theme.turf }
        let ratio = min(1, value / first)
        return Theme.turf.opacity(0.35 + 0.65 * ratio)
    }

    // MARK: Gauge

    /// Compact context under the detail hero ring (which already carries the score) — the run /
    /// sprint counts and a one-line explanation of what workrate measures.
    private var workrateSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                SummaryChip(value: "\(report.runCount)", label: "Runs", tint: Theme.turf)
                SummaryChip(value: "\(report.sprintCount)", label: "Sprints", tint: Theme.sprint)
            }
            Text("Workrate is a composite of distance rate, sprint frequency, and high-intensity share.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Distance per minute

    private var distancePerMinuteChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Distance per Minute").sectionHeading()
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
            .frame(height: 170)
            .fullBleed()
            .overlay {
                if report.distancePerMinute.isEmpty {
                    Text("No per-minute data").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func barShading(for meters: Double) -> LinearGradient {
        // Single-hue pace fill: taller minutes read brighter, no hue jump.
        let intensity = min(1, meters / 180)
        return LinearGradient(
            colors: [Theme.pace.opacity(0.15), Theme.pace.opacity(0.55 + 0.45 * intensity)],
            startPoint: .bottom, endPoint: .top
        )
    }

    // MARK: Speed zones donut

    private var speedZoneDonut: some View {
        let zones = speedZoneData
        return VStack(alignment: .leading, spacing: 8) {
            Text("Speed Zones").sectionHeading()
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
        // Coherent cool → hot ramp.
        return [
            Zone(name: "Standing", seconds: z.standing, color: Color.gray),
            Zone(name: "Walking", seconds: z.walking, color: Theme.pace),
            Zone(name: "Jogging", seconds: z.jogging, color: Theme.turf),
            Zone(name: "Running", seconds: z.running, color: Theme.sprint),
            Zone(name: "Sprinting", seconds: z.sprinting, color: Theme.heart)
        ].filter { $0.seconds > 0 }
    }

    // MARK: Heart rate line

    private var heartRateChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Heart Rate").sectionHeading()
            Chart(Array(detail.heartRateSeries.enumerated()), id: \.offset) { _, sample in
                AreaMark(
                    x: .value("Time", sample.date),
                    y: .value("BPM", sample.bpm)
                )
                .foregroundStyle(LinearGradient(colors: [Theme.heart.opacity(0.35), Theme.heart.opacity(0.02)],
                                                startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.catmullRom)
                LineMark(
                    x: .value("Time", sample.date),
                    y: .value("BPM", sample.bpm)
                )
                .foregroundStyle(Theme.heart)
                .interpolationMethod(.catmullRom)
            }
            .chartYAxisLabel("bpm")
            .frame(height: 150)
            .fullBleed()
        }
    }
}

private extension Text {
    /// Larger rounded-bold module heading used across the workrate charts — the "expansive"
    /// heading weight the full-bleed hero charts sit under.
    func sectionHeading() -> Text {
        font(.system(.title3, design: .rounded).weight(.bold))
    }
}

private extension TrainingLoadService.AcuteChronicLoad.Status {
    /// The one-word coach-facing label for the ratio's zone.
    var word: String {
        switch self {
        case .balanced: return "balanced"
        case .ramping: return "ramping"
        case .high: return "high"
        }
    }

    /// Semantic tint: turf when balanced, sprint amber while ramping, loss red when high.
    var tint: Color {
        switch self {
        case .balanced: return Theme.turf
        case .ramping: return Theme.sprint
        case .high: return Theme.loss
        }
    }
}
