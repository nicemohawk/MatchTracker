import Foundation
import CoreGraphics

// MARK: - Speed helpers

/// Per-point speed in m/s: the reported point speed when valid, otherwise a GPS-derived
/// point-to-point speed (distance / elapsed time).
func rawPointSpeeds(_ track: [TrackPoint]) -> [Double] {
    guard !track.isEmpty else { return [] }
    var speeds = [Double](repeating: 0, count: track.count)
    for index in track.indices {
        if track[index].speedMetersPerSecond >= 0 {
            speeds[index] = track[index].speedMetersPerSecond
        } else if index > 0 {
            let dt = track[index].timestamp.timeIntervalSince(track[index - 1].timestamp)
            speeds[index] = dt > 0 ? haversineMeters(track[index - 1].coordinate, track[index].coordinate) / dt : 0
        }
    }
    // The first point has no predecessor to derive from; borrow its neighbor's speed.
    if track[0].speedMetersPerSecond < 0 && track.count > 1 {
        speeds[0] = speeds[1]
    }
    return speeds
}

/// `rawPointSpeeds` smoothed with a 3-point moving average (endpoints left untouched).
func smoothedPointSpeeds(_ track: [TrackPoint]) -> [Double] {
    let raw = rawPointSpeeds(track)
    guard raw.count >= 3 else { return raw }
    var smoothed = raw
    for index in 1..<(raw.count - 1) {
        smoothed[index] = (raw[index - 1] + raw[index] + raw[index + 1]) / 3
    }
    return smoothed
}

/// Whether a timestamp falls inside any of the intervals.
func isWithin(_ date: Date, intervals: [DateInterval]) -> Bool {
    intervals.contains { $0.contains(date) }
}

// MARK: - Analytics

/// Canonical speed thresholds (m/s), shared by run detection and workrate speed-zone bucketing
/// so the two never drift apart. Each value is the boundary *entering* the next-faster zone.
public enum SpeedThresholds {
    public static let walking = 0.5     // standing → walking
    public static let jogging = 2.0     // walking → jogging
    public static let running = 4.0     // jogging → running
    public static let sprinting = 5.5   // running → sprinting
}

public struct HeatmapGrid: Codable, Sendable {
    public var columns: Int   // along long axis
    public var rows: Int
    public var cells: [Double]  // row-major, normalized 0...1 (max cell == 1), 0 if empty

    public init(columns: Int, rows: Int, cells: [Double]) {
        self.columns = columns
        self.rows = rows
        self.cells = cells
    }

    public subscript(column: Int, row: Int) -> Double {
        get {
            let index = row * columns + column
            guard index >= 0, index < cells.count else { return 0 }
            return cells[index]
        }
    }

    /// Maximum time (seconds) a single sample can be weighted by (guards against long GPS gaps).
    private static let maxSampleWeight = 10.0

    /// Bins time-weighted samples. Only points inside playingIntervals count (nil = all).
    /// Each sample is weighted by the gap to the next sample (capped at 10 s). The busiest
    /// cell is normalized to 1.0.
    public static func compute(points: [TrackPoint], projector: FieldProjector,
                               columns: Int, rows: Int,
                               playingIntervals: [DateInterval]?) -> HeatmapGrid {
        let columnCount = max(0, columns)
        let rowCount = max(0, rows)
        var cells = [Double](repeating: 0, count: columnCount * rowCount)
        guard columnCount > 0, rowCount > 0 else {
            return HeatmapGrid(columns: columns, rows: rows, cells: cells)
        }

        let ordered = points.sorted { $0.timestamp < $1.timestamp }
        for index in ordered.indices {
            let point = ordered[index]
            if let intervals = playingIntervals, !isWithin(point.timestamp, intervals: intervals) { continue }

            // Time-weight by the gap to the next sample, capped; the final sample has no gap.
            guard index < ordered.count - 1 else { continue }
            let gap = ordered[index + 1].timestamp.timeIntervalSince(point.timestamp)
            let weight = min(max(0, gap), maxSampleWeight)
            guard weight > 0 else { continue }

            guard let normalized = projector.normalizedPoint(for: point.coordinate) else { continue }
            let column = min(max(Int(Double(normalized.x) * Double(columnCount)), 0), columnCount - 1)
            let row = min(max(Int(Double(normalized.y) * Double(rowCount)), 0), rowCount - 1)
            cells[row * columnCount + column] += weight
        }

        if let peak = cells.max(), peak > 0 {
            cells = cells.map { $0 / peak }
        }
        return HeatmapGrid(columns: columns, rows: rows, cells: cells)
    }
}

public enum RunIntensity: String, Codable, CaseIterable, Sendable { case jog, run, sprint }

public struct RunSegment: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var interval: DateInterval
    public var distanceMeters: Double
    public var peakSpeed: Double
    public var averageSpeed: Double
    public var intensity: RunIntensity
    public var pointRange: Range<Int>   // indices into source track

    public init(id: UUID = UUID(), interval: DateInterval, distanceMeters: Double, peakSpeed: Double, averageSpeed: Double, intensity: RunIntensity, pointRange: Range<Int>) {
        self.id = id
        self.interval = interval
        self.distanceMeters = distanceMeters
        self.peakSpeed = peakSpeed
        self.averageSpeed = averageSpeed
        self.intensity = intensity
        self.pointRange = pointRange
    }
}

public struct RunDetectorConfiguration: Sendable {
    public var jogThreshold: Double      // m/s, default 2.0
    public var runThreshold: Double      // default 4.0
    public var sprintThreshold: Double   // default 5.5
    public var minimumDuration: TimeInterval // default 2.0
    public var mergeGap: TimeInterval    // default 1.5 s below-threshold gap merged

    public init() {
        self.jogThreshold = SpeedThresholds.jogging
        self.runThreshold = SpeedThresholds.running
        self.sprintThreshold = SpeedThresholds.sprinting
        self.minimumDuration = 2.0
        self.mergeGap = 1.5
    }

    /// Speed thresholds scaled for the match context: on a shorter field the same effort tops out
    /// at a lower speed, so each threshold multiplies by `context.pitchScale`. Sensible floors keep
    /// a scaled sprint from collapsing into a brisk jog (jog ≥ 1.6, run ≥ 2.8, sprint ≥ 4.0 m/s),
    /// so a hard burst on a small turf field still registers as a sprint even below 5.5 m/s.
    public static func scaled(for context: MatchContext) -> RunDetectorConfiguration {
        var configuration = RunDetectorConfiguration()
        let scale = context.pitchScale
        configuration.jogThreshold = max(configuration.jogThreshold * scale, 1.6)
        configuration.runThreshold = max(configuration.runThreshold * scale, 2.8)
        configuration.sprintThreshold = max(configuration.sprintThreshold * scale, 4.0)
        return configuration
    }
}

public enum RunDetector {
    /// Speed-threshold segmentation with hysteresis + gap merging. Uses GPS-derived speed
    /// (point-to-point) when speedMetersPerSecond invalid.
    public static func detectRuns(in track: [TrackPoint], configuration: RunDetectorConfiguration) -> [RunSegment] {
        guard track.count >= 2 else { return [] }
        let ordered = track.sorted { $0.timestamp < $1.timestamp }
        let speeds = smoothedPointSpeeds(ordered)

        let startThreshold = configuration.jogThreshold
        let endThreshold = configuration.jogThreshold * 0.8

        // Hysteresis segmentation: enter a run at the jog threshold, leave once speed drops
        // below 80% of it. Segments are inclusive index ranges into `ordered`.
        var rawSegments: [(start: Int, end: Int)] = []
        var inRun = false
        var segmentStart = 0
        for index in speeds.indices {
            if inRun {
                if speeds[index] < endThreshold {
                    rawSegments.append((segmentStart, index - 1))
                    inRun = false
                }
            } else if speeds[index] >= startThreshold {
                inRun = true
                segmentStart = index
            }
        }
        if inRun {
            rawSegments.append((segmentStart, speeds.count - 1))
        }

        // Merge segments separated by a below-threshold gap shorter than mergeGap.
        var merged: [(start: Int, end: Int)] = []
        for segment in rawSegments {
            if let last = merged.last {
                let gap = ordered[segment.start].timestamp.timeIntervalSince(ordered[last.end].timestamp)
                if gap < configuration.mergeGap {
                    merged[merged.count - 1] = (last.start, segment.end)
                    continue
                }
            }
            merged.append(segment)
        }

        // Build the run segments, dropping anything shorter than the minimum duration.
        var runs: [RunSegment] = []
        for segment in merged {
            let startDate = ordered[segment.start].timestamp
            let endDate = ordered[segment.end].timestamp
            let duration = endDate.timeIntervalSince(startDate)
            guard duration >= configuration.minimumDuration else { continue }

            var distance = 0.0
            var peakSpeed = 0.0
            var speedSum = 0.0
            for index in segment.start...segment.end {
                peakSpeed = max(peakSpeed, speeds[index])
                speedSum += speeds[index]
                if index > segment.start {
                    distance += haversineMeters(ordered[index - 1].coordinate, ordered[index].coordinate)
                }
            }
            let averageSpeed = speedSum / Double(segment.end - segment.start + 1)
            let intensity: RunIntensity
            if peakSpeed >= configuration.sprintThreshold {
                intensity = .sprint
            } else if peakSpeed >= configuration.runThreshold {
                intensity = .run
            } else {
                intensity = .jog
            }

            runs.append(RunSegment(
                interval: DateInterval(start: startDate, end: endDate),
                distanceMeters: distance,
                peakSpeed: peakSpeed,
                averageSpeed: averageSpeed,
                intensity: intensity,
                pointRange: segment.start..<(segment.end + 1)
            ))
        }
        return runs
    }
}

public struct SpeedZones: Codable, Sendable {   // seconds in each zone
    public var standing: TimeInterval   // < 0.5 m/s
    public var walking: TimeInterval    // 0.5–2
    public var jogging: TimeInterval    // 2–4
    public var running: TimeInterval    // 4–5.5
    public var sprinting: TimeInterval  // > 5.5

    public init(standing: TimeInterval = 0, walking: TimeInterval = 0, jogging: TimeInterval = 0, running: TimeInterval = 0, sprinting: TimeInterval = 0) {
        self.standing = standing
        self.walking = walking
        self.jogging = jogging
        self.running = running
        self.sprinting = sprinting
    }
}

/// The 0–100 sub-scores that fed `workrateScore`, one per calibration curve. Each is populated
/// only when its signal contributed to the blend (GPS components stay `nil` on the HR-only indoor
/// path, `heartRate` stays `nil` on the GPS-only path), so a reader can render exactly the bars
/// that drove the score. Additive/optional for wire compatibility.
public struct WorkrateComponents: Codable, Sendable {
    public var distanceRate: Double?    // distance-rate curve score
    public var highIntensity: Double?   // high-intensity-share curve score
    public var sprints: Double?         // sprint-rate curve score
    public var heartRate: Double?       // %HRR effort curve score

    public init(distanceRate: Double? = nil, highIntensity: Double? = nil, sprints: Double? = nil, heartRate: Double? = nil) {
        self.distanceRate = distanceRate
        self.highIntensity = highIntensity
        self.sprints = sprints
        self.heartRate = heartRate
    }
}

public struct WorkrateReport: Codable, Sendable {
    public var totalDistanceMeters: Double
    public var distancePerMinute: [Double]      // meters covered in each minute-on-pitch
    public var speedZones: SpeedZones
    public var sprintCount: Int
    public var runCount: Int
    public var averageHeartRate: Double?        // filled by app layer when HR available
    public var timeOnPitch: TimeInterval
    /// 0–100 composite: distance rate, sprint frequency, high-intensity share, and — when heart
    /// rate is available — %HRR-based effort. Calibrated to stay comparable across match formats.
    public var workrateScore: Double
    /// Which signals fed `workrateScore`: `"gps+hr"`, `"gps"` (legacy GPS-only), or `"hr"`
    /// (indoor / no usable GPS). Additive/optional for wire compatibility.
    public var effortSource: String?
    /// The per-curve 0–100 sub-scores behind `workrateScore`. Additive/optional.
    public var components: WorkrateComponents?
    /// `true` when the score rests on a thin sample — under 10 min on pitch, or (HR-only) fewer
    /// than 15 on-pitch heart-rate readings. Additive/optional.
    public var isLowConfidence: Bool?

    public init(totalDistanceMeters: Double = 0, distancePerMinute: [Double] = [], speedZones: SpeedZones = SpeedZones(), sprintCount: Int = 0, runCount: Int = 0, averageHeartRate: Double? = nil, timeOnPitch: TimeInterval = 0, workrateScore: Double = 0, effortSource: String? = nil, components: WorkrateComponents? = nil, isLowConfidence: Bool? = nil) {
        self.totalDistanceMeters = totalDistanceMeters
        self.distancePerMinute = distancePerMinute
        self.speedZones = speedZones
        self.sprintCount = sprintCount
        self.runCount = runCount
        self.averageHeartRate = averageHeartRate
        self.timeOnPitch = timeOnPitch
        self.workrateScore = workrateScore
        self.effortSource = effortSource
        self.components = components
        self.isLowConfidence = isLowConfidence
    }
}

/// Monotone piecewise-linear calibration curves that turn raw workrate inputs into 0–100
/// component sub-scores. These replace the old linear "ratio against an elite reference" scaling,
/// which pinned a solid amateur match into the low 50s because it measured everything as a
/// fraction of a professional's output. Each anchor is documented against the product's intuition
/// bands: casual kickabout 25–45, average amateur 50–65, strong amateur 65–80, pro-like 80–95.
enum WorkrateCalibration {
    typealias Anchor = (x: Double, score: Double)

    /// distanceRate — meters covered per on-pitch minute → 0–100. Full-pitch reference.
    ///   30 →  5  (barely moving: mostly stood still — clamps here, no gifted floor)
    ///   50 → 20  (casual: lots of standing, the occasional stroll)
    ///   70 → 45  (average amateur floor)
    ///   90 → 65  (strong amateur, covers real ground)
    ///  110 → 80  (pro-like full-pitch distance rate)
    ///  130 → 92  (elite ceiling; saturates above)
    static let distanceRate: [Anchor] = [(30, 5), (50, 20), (70, 45), (90, 65), (110, 80), (130, 92)]

    /// sprintRate — sprints per 10 on-pitch minutes → 0–100.
    ///  0.0 →  3  (no bursts at all — clamps here)
    ///  0.5 → 30  (casual: an odd chase)
    ///  1.5 → 55  (average amateur)
    ///  3.0 → 75  (strong amateur, repeated bursts)
    ///  5.0 → 90  (pro-like sprint density; saturates above)
    static let sprintRate: [Anchor] = [(0, 3), (0.5, 30), (1.5, 55), (3, 75), (5, 90)]

    /// highIntensityShare — fraction of on-pitch time in running+sprinting zones → 0–100.
    ///  0.00 →  3  (never got out of a walk — clamps here)
    ///  0.05 → 30  (casual)
    ///  0.10 → 55  (average amateur)
    ///  0.18 → 75  (strong amateur)
    ///  0.28 → 90  (pro-like; saturates above)
    static let highIntensityShare: [Anchor] = [(0, 3), (0.05, 30), (0.10, 55), (0.18, 75), (0.28, 90)]

    /// hrEffort — time-weighted mean %HRR on pitch → 0–100. Physiological, so it is NOT format-scaled.
    ///  0.35 →  8  (near-resting: coasting, not exerting — clamps here)
    ///  0.45 → 35  (casual: aerobic cruising)
    ///  0.55 → 55  (average amateur)
    ///  0.65 → 72  (strong amateur, sustained tempo)
    ///  0.75 → 85  (pro-like)
    ///  0.85 → 95  (near-max sustained; saturates above)
    static let hrEffort: [Anchor] = [(0.35, 8), (0.45, 35), (0.55, 55), (0.65, 72), (0.75, 85), (0.85, 95)]

    /// Piecewise-linear lookup with clamped (saturated) ends: below the first anchor returns the
    /// first score, above the last returns the last score.
    static func score(_ value: Double, curve: [Anchor]) -> Double {
        guard let first = curve.first, let last = curve.last else { return 0 }
        if value <= first.x { return first.score }
        if value >= last.x { return last.score }
        for index in 1..<curve.count {
            let lower = curve[index - 1], upper = curve[index]
            if value <= upper.x {
                let t = (value - lower.x) / (upper.x - lower.x)
                return lower.score + t * (upper.score - lower.score)
            }
        }
        return last.score
    }

    /// Format scaling lives on the INPUT side: the anchor x-positions shift by `factor` while the
    /// scores stay put, so a short-field player reaches the same band for less raw distance/sprints.
    static func scaled(_ curve: [Anchor], by factor: Double) -> [Anchor] {
        curve.map { (x: $0.x * factor, score: $0.score) }
    }
}

public enum WorkrateAnalyzer {
    /// Reference distance rate (m/min) anchoring the full-pitch distance curve (its 110→80 anchor).
    private static let matchDistanceRateReference = 110.0
    /// Reference distance rate (m/min) for a small-sided pitch, before pitch-scale adjustment. The
    /// ratio `smallSided·pitchScale / match` scales the distance curve's x-anchors on short fields.
    private static let smallSidedDistanceRateReference = 95.0
    /// Default resting / max heart rates used to normalize %HRR when the context carries none.
    private static let defaultRestingHeartRate = 60.0
    private static let defaultMaxHeartRate = 190.0
    /// Longest gap (seconds) a single heart-rate sample is time-weighted across (sparse indoor HR).
    private static let maxHeartRateSampleWeight = 30.0
    /// On-pitch time (seconds) below which any score is flagged low-confidence.
    private static let lowConfidenceMinimumSeconds = 600.0
    /// On-pitch HR readings below which an HR-only score is flagged low-confidence.
    private static let lowConfidenceMinimumHeartRateSamples = 15

    /// Legacy GPS-only signature. Delegates to the format-aware overload with a full-size match
    /// context and no heart rate, preserving the historical 40/30/30 GPS-only weighting.
    public static func analyze(track: [TrackPoint], runs: [RunSegment],
                               playingIntervals: [DateInterval]) -> WorkrateReport {
        analyze(track: track, runs: runs, playingIntervals: playingIntervals,
                heartRate: [], context: MatchContext(format: .match))
    }

    /// Format-transcendent workrate. Distance/sprint references scale with the pitch, and the
    /// effort components re-weight by which signals are actually available so a hard shift reads
    /// the same whether it was measured on a full pitch by GPS, on a small turf field by GPS+HR,
    /// or indoors by heart rate alone:
    ///   - GPS+HR: distanceRate 30 / highIntensity 25 / sprintFrequency 20 / hrEffort 25
    ///   - GPS-only (legacy): distanceRate 40 / highIntensity 30 / sprintFrequency 30
    ///   - HR-only (indoor, or no usable GPS): hrEffort 100
    /// Indoor always scores from heart rate even when sparse GPS exists.
    public static func analyze(track: [TrackPoint], runs: [RunSegment],
                               playingIntervals: [DateInterval],
                               heartRate: [HeartRateSample],
                               context: MatchContext) -> WorkrateReport {
        let ordered = track.sorted { $0.timestamp < $1.timestamp }
        let speeds = rawPointSpeeds(ordered)

        var zones = SpeedZones()
        var totalDistance = 0.0
        var distancePerMinute: [Double] = []
        var cumulativeOnPitch = 0.0

        for index in 0..<ordered.count {
            let point = ordered[index]
            guard isWithin(point.timestamp, intervals: playingIntervals) else { continue }
            guard index < ordered.count - 1 else { continue }
            let next = ordered[index + 1]
            // Only integrate across a step where the wearer stays on the pitch.
            guard isWithin(next.timestamp, intervals: playingIntervals) else { continue }
            let dt = next.timestamp.timeIntervalSince(point.timestamp)
            guard dt > 0 else { continue }

            let speed = speeds[index]
            if speed < SpeedThresholds.walking { zones.standing += dt }
            else if speed < SpeedThresholds.jogging { zones.walking += dt }
            else if speed < SpeedThresholds.running { zones.jogging += dt }
            else if speed < SpeedThresholds.sprinting { zones.running += dt }
            else { zones.sprinting += dt }

            let stepDistance = haversineMeters(point.coordinate, next.coordinate)
            totalDistance += stepDistance

            let minuteIndex = Int(cumulativeOnPitch / 60)
            while distancePerMinute.count <= minuteIndex { distancePerMinute.append(0) }
            distancePerMinute[minuteIndex] += stepDistance
            cumulativeOnPitch += dt
        }

        let timeOnPitch = playingIntervals.reduce(0) { $0 + $1.duration }
        let sprintCount = runs.filter { $0.intensity == .sprint }.count
        let runCount = runs.filter { $0.intensity == .run || $0.intensity == .sprint }.count

        let scale = context.pitchScale
        let minutes = timeOnPitch / 60

        // Each component is a 0–100 calibration-curve score (see `WorkrateCalibration`). Format
        // scaling shifts the curves' x-anchors so a short-field player reaches the same band for
        // less raw output, rather than curving the final blend.

        // Distance: the distance curve's m/min anchors scale by the format's reference ratio.
        let distanceFactor: Double
        switch context.format {
        case .match: distanceFactor = 1.0
        case .smallSided: distanceFactor = (smallSidedDistanceRateReference * scale) / matchDistanceRateReference
        case .indoor: distanceFactor = 1.0   // unused (HR-only)
        }
        let distanceRate = minutes > 0 ? totalDistance / minutes : 0
        let distanceComponent = WorkrateCalibration.score(
            distanceRate, curve: WorkrateCalibration.scaled(WorkrateCalibration.distanceRate, by: distanceFactor))

        // High-intensity share: a physical fraction of on-pitch time, so its curve is not scaled.
        let activeTime = zones.standing + zones.walking + zones.jogging + zones.running + zones.sprinting
        let highIntensityShare = activeTime > 0 ? (zones.running + zones.sprinting) / activeTime : 0
        let highIntensityComponent = WorkrateCalibration.score(
            highIntensityShare, curve: WorkrateCalibration.highIntensityShare)

        // Sprints: the sprint curve's per-10-min anchors scale by pitchScale (shorter, more
        // frequent bursts are the norm on a small field), matching the legacy sprint reference.
        let sprintRatePerTenMinutes = minutes > 0 ? Double(sprintCount) / minutes * 10 : 0
        let sprintComponent = WorkrateCalibration.score(
            sprintRatePerTenMinutes, curve: WorkrateCalibration.scaled(WorkrateCalibration.sprintRate, by: scale))

        // Heart rate: mean %HRR on pitch mapped through the (unscaled) effort curve.
        let heartRateReserve = meanHeartRateReserve(samples: heartRate, playingIntervals: playingIntervals)
        let heartRateComponent = heartRateReserve.mean.map {
            WorkrateCalibration.score($0, curve: WorkrateCalibration.hrEffort)
        } ?? 0

        // Blend by signal availability with the existing weights. Sub-scores are already 0–100 and
        // the weights sum to 1, so the weighted mean is the score — no further curving. Indoor is
        // HR-only regardless of any sparse GPS. `components` carries only the signals that fed it.
        let hasHeartRate = !heartRate.isEmpty
        let effortSource: String
        let rawScore: Double
        let components: WorkrateComponents
        let shortStint = timeOnPitch < lowConfidenceMinimumSeconds
        var isLowConfidence = shortStint
        if context.format == .indoor {
            effortSource = "hr"
            rawScore = heartRateComponent
            components = WorkrateComponents(heartRate: heartRateComponent)
            isLowConfidence = shortStint || heartRateReserve.onPitchSampleCount < lowConfidenceMinimumHeartRateSamples
        } else if hasHeartRate {
            effortSource = "gps+hr"
            rawScore = 0.30 * distanceComponent + 0.25 * highIntensityComponent
                     + 0.20 * sprintComponent + 0.25 * heartRateComponent
            components = WorkrateComponents(distanceRate: distanceComponent, highIntensity: highIntensityComponent,
                                            sprints: sprintComponent, heartRate: heartRateComponent)
        } else {
            effortSource = "gps"
            rawScore = 0.40 * distanceComponent + 0.30 * highIntensityComponent + 0.30 * sprintComponent
            components = WorkrateComponents(distanceRate: distanceComponent, highIntensity: highIntensityComponent,
                                            sprints: sprintComponent)
        }
        let workrateScore = min(max(rawScore, 0), 100)

        return WorkrateReport(
            totalDistanceMeters: totalDistance,
            distancePerMinute: distancePerMinute,
            speedZones: zones,
            sprintCount: sprintCount,
            runCount: runCount,
            averageHeartRate: nil,
            timeOnPitch: timeOnPitch,
            workrateScore: workrateScore,
            effortSource: effortSource,
            components: components,
            isLowConfidence: isLowConfidence
        )
    }

    /// Time-weighted mean heart-rate reserve (%HRR) over on-pitch samples, plus the on-pitch sample
    /// count (used for low-confidence flagging). Each sample is weighted by the gap to the next
    /// (capped), so uneven sampling doesn't skew the mean. `mean` is nil when nothing lands on pitch.
    private static func meanHeartRateReserve(samples: [HeartRateSample], playingIntervals: [DateInterval]) -> (mean: Double?, onPitchSampleCount: Int) {
        guard !samples.isEmpty else { return (nil, 0) }
        let reserve = defaultMaxHeartRate - defaultRestingHeartRate
        guard reserve > 0 else { return (nil, 0) }

        let ordered = samples.sorted { $0.date < $1.date }
        var weightedReserveSum = 0.0
        var totalWeight = 0.0
        var onPitchSampleCount = 0
        for index in ordered.indices {
            let sample = ordered[index]
            guard isWithin(sample.date, intervals: playingIntervals) else { continue }
            onPitchSampleCount += 1
            guard index < ordered.count - 1 else { continue }
            let gap = ordered[index + 1].date.timeIntervalSince(sample.date)
            let weight = min(max(0, gap), maxHeartRateSampleWeight)
            guard weight > 0 else { continue }
            let hrr = min(max((sample.bpm - defaultRestingHeartRate) / reserve, 0), 1)
            weightedReserveSum += hrr * weight
            totalWeight += weight
        }
        guard totalWeight > 0 else { return (nil, onPitchSampleCount) }
        return (weightedReserveSum / totalWeight, onPitchSampleCount)
    }
}

public enum PositionRole: String, Codable, CaseIterable, Sendable { case goalkeeper, defender, midfielder, forward }
public enum PositionSide: String, Codable, CaseIterable, Sendable { case left, center, right }

public struct PositionEstimate: Codable, Sendable {
    public var role: PositionRole
    public var side: PositionSide
    public var confidence: Double        // 0–1
    public var meanPoint: CGPoint        // normalized field coords
    /// Per-period mean points let the UI show "played RB first half, RW second".
    public var periodMeanPoints: [CGPoint]
    /// Sport-specific label for `role`, drawn from `SportProfile.positionRoles` (e.g. "attack"
    /// for lacrosse, "midfielder" for soccer). Defaults to the soccer role name.
    public var roleLabel: String

    public init(role: PositionRole, side: PositionSide, confidence: Double, meanPoint: CGPoint, periodMeanPoints: [CGPoint], roleLabel: String = "") {
        self.role = role
        self.side = side
        self.confidence = confidence
        self.meanPoint = meanPoint
        self.periodMeanPoints = periodMeanPoints
        self.roleLabel = roleLabel.isEmpty ? role.rawValue : roleLabel
    }
}

public enum PositionAnalyzer {
    /// Attack-direction ambiguity is resolved per period; roles are direction-independent.
    /// Role comes from the long-axis distribution folded around midfield (GK/DEF sit near an
    /// end, MID central, FWD ranges the front third); side comes from the short-axis mean with
    /// per-period flip correction (periods are reflected so their long-axis means agree).
    /// `sport` maps the folded-axis role onto `sport.positionRoles` (ordered defensive ->
    /// offensive) to fill `PositionEstimate.roleLabel`. The keeper-like role is only produced for
    /// sports whose profile has one (`hasGoalkeeper`); the returned `role`/`side` enums stay
    /// soccer-shaped for API compatibility. Defaults to soccer, so existing call sites are unchanged.
    public static func estimate(points: [TrackPoint], projector: FieldProjector,
                                events: [MatchEvent], playingIntervals: [DateInterval],
                                sport: SportProfile = .soccer) -> PositionEstimate {
        let periods = derivePeriods(events: events, points: points)

        // Normalized field points for each period, restricted to on-pitch time.
        var periodClouds: [[CGPoint]] = []
        for period in periods {
            let cloud = points
                .filter { period.contains($0.timestamp) && isWithin($0.timestamp, intervals: playingIntervals) }
                .compactMap { projector.normalizedPoint(for: $0.coordinate) }
            if !cloud.isEmpty { periodClouds.append(cloud) }
        }

        guard let reference = periodClouds.first else {
            return PositionEstimate(role: .midfielder, side: .center, confidence: 0,
                                    meanPoint: CGPoint(x: 0.5, y: 0.5), periodMeanPoints: [],
                                    roleLabel: label(for: .midfielder, sport: sport))
        }

        // Flip-align later periods: switching ends mirrors both axes, so reflect (x,y)->(1-x,1-y)
        // for any period whose long-axis mean lands closer to the reference after reflection.
        let referenceMeanX = mean(reference.map { Double($0.x) })
        var alignedClouds: [[CGPoint]] = []
        var periodMeanPoints: [CGPoint] = []
        for (index, cloud) in periodClouds.enumerated() {
            let cloudMeanX = mean(cloud.map { Double($0.x) })
            let shouldFlip = index > 0 && abs((1 - cloudMeanX) - referenceMeanX) < abs(cloudMeanX - referenceMeanX)
            let aligned = cloud.map { shouldFlip ? CGPoint(x: 1 - $0.x, y: 1 - $0.y) : $0 }
            alignedClouds.append(aligned)
            periodMeanPoints.append(CGPoint(
                x: mean(aligned.map { Double($0.x) }),
                y: mean(aligned.map { Double($0.y) })
            ))
        }

        let all = alignedClouds.flatMap { $0 }
        let xs = all.map { Double($0.x) }
        let ys = all.map { Double($0.y) }
        let meanX = mean(xs)
        let meanY = mean(ys)
        let spreadX = standardDeviation(xs)
        let spreadY = standardDeviation(ys)

        // Fold the long axis around midfield: 0 = central, 0.5 = pinned at an end.
        let foldedMean = mean(xs.map { abs($0 - 0.5) })
        let outerFraction = Double(xs.filter { abs($0 - 0.5) > 0.35 }.count) / Double(xs.count)

        let role: PositionRole
        if sport.hasGoalkeeper && outerFraction > 0.6 && spreadX < 0.08 {
            role = .goalkeeper                 // pinned to the outer 15% with almost no spread
        } else if foldedMean < 0.20 {
            role = .midfielder                 // lives around the centre of the pitch
        } else if spreadX >= 0.085 {
            role = .forward                    // near an end but roams the front
        } else {
            role = .defender                   // holds a compact zone near an end
        }

        let side: PositionSide
        if meanY < 0.42 {
            side = .left
        } else if meanY > 0.58 {
            side = .right
        } else {
            side = .center
        }

        // Tighter clusters read as more confident position estimates.
        let confidence = max(0, min(1, 1 - 2 * (spreadX + spreadY)))

        return PositionEstimate(
            role: role,
            side: side,
            confidence: confidence,
            meanPoint: CGPoint(x: meanX, y: meanY),
            periodMeanPoints: periodMeanPoints,
            roleLabel: label(for: role, sport: sport)
        )
    }

    /// Maps a soccer-shaped `PositionRole` onto `sport.positionRoles` (ordered defensive ->
    /// offensive). The role's position on the defensive->offensive continuum is projected onto
    /// the sport's vocabulary length, so soccer maps 1:1 while other sports get their nearest
    /// role name. For keeper-less sports the keeper slot is dropped from the continuum.
    static func label(for role: PositionRole, sport: SportProfile) -> String {
        guard !sport.positionRoles.isEmpty else { return role.rawValue }

        let ordering: [PositionRole] = sport.hasGoalkeeper
            ? [.goalkeeper, .defender, .midfielder, .forward]
            : [.defender, .midfielder, .forward]
        let index = ordering.firstIndex(of: role) ?? 0

        guard ordering.count > 1 else { return sport.positionRoles[0] }
        let fraction = Double(index) / Double(ordering.count - 1)
        let mapped = Int((fraction * Double(sport.positionRoles.count - 1)).rounded())
        return sport.positionRoles[min(max(mapped, 0), sport.positionRoles.count - 1)]
    }

    /// Periods from periodStart/periodEnd event pairs, or the whole track span when absent.
    private static func derivePeriods(events: [MatchEvent], points: [TrackPoint]) -> [DateInterval] {
        let periodEvents = events
            .filter { $0.kind == .periodStart || $0.kind == .periodEnd }
            .sorted { $0.date < $1.date }

        let latestPointDate = points.map(\.timestamp).max()
        var periods: [DateInterval] = []
        var openStart: Date?
        for event in periodEvents {
            if event.kind == .periodStart {
                openStart = event.date
            } else if let start = openStart, event.date > start {
                periods.append(DateInterval(start: start, end: event.date))
                openStart = nil
            }
        }
        if let start = openStart, let end = latestPointDate, end > start {
            periods.append(DateInterval(start: start, end: end))
        }

        if periods.isEmpty,
           let first = points.map(\.timestamp).min(),
           let last = latestPointDate, last > first {
            periods = [DateInterval(start: first, end: last)]
        }
        return periods
    }
}
