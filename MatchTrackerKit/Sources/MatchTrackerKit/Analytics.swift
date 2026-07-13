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

public struct WorkrateReport: Codable, Sendable {
    public var totalDistanceMeters: Double
    public var distancePerMinute: [Double]      // meters covered in each minute-on-pitch
    public var speedZones: SpeedZones
    public var sprintCount: Int
    public var runCount: Int
    public var averageHeartRate: Double?        // filled by app layer when HR available
    public var timeOnPitch: TimeInterval
    /// 0–100 composite: distance rate, sprint frequency, high-intensity share.
    public var workrateScore: Double

    public init(totalDistanceMeters: Double = 0, distancePerMinute: [Double] = [], speedZones: SpeedZones = SpeedZones(), sprintCount: Int = 0, runCount: Int = 0, averageHeartRate: Double? = nil, timeOnPitch: TimeInterval = 0, workrateScore: Double = 0) {
        self.totalDistanceMeters = totalDistanceMeters
        self.distancePerMinute = distancePerMinute
        self.speedZones = speedZones
        self.sprintCount = sprintCount
        self.runCount = runCount
        self.averageHeartRate = averageHeartRate
        self.timeOnPitch = timeOnPitch
        self.workrateScore = workrateScore
    }
}

public enum WorkrateAnalyzer {
    /// Reference distance rate (m/min) that saturates the distance component of the score.
    private static let distanceRateReference = 110.0
    /// Reference sprint frequency (sprints/min) that saturates the sprint component.
    private static let sprintFrequencyReference = 0.5

    public static func analyze(track: [TrackPoint], runs: [RunSegment],
                               playingIntervals: [DateInterval]) -> WorkrateReport {
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

        let minutes = timeOnPitch / 60
        let distanceRate = minutes > 0 ? totalDistance / minutes : 0
        let distanceComponent = min(distanceRate / distanceRateReference, 1)

        let activeTime = zones.standing + zones.walking + zones.jogging + zones.running + zones.sprinting
        let highIntensityShare = activeTime > 0 ? (zones.running + zones.sprinting) / activeTime : 0

        let sprintFrequency = minutes > 0 ? Double(sprintCount) / minutes : 0
        let sprintComponent = min(sprintFrequency / sprintFrequencyReference, 1)

        let rawScore = 100 * (0.4 * distanceComponent + 0.3 * min(highIntensityShare, 1) + 0.3 * sprintComponent)
        let workrateScore = min(max(rawScore, 0), 100)

        return WorkrateReport(
            totalDistanceMeters: totalDistance,
            distancePerMinute: distancePerMinute,
            speedZones: zones,
            sprintCount: sprintCount,
            runCount: runCount,
            averageHeartRate: nil,
            timeOnPitch: timeOnPitch,
            workrateScore: workrateScore
        )
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

    public init(role: PositionRole, side: PositionSide, confidence: Double, meanPoint: CGPoint, periodMeanPoints: [CGPoint]) {
        self.role = role
        self.side = side
        self.confidence = confidence
        self.meanPoint = meanPoint
        self.periodMeanPoints = periodMeanPoints
    }
}

public enum PositionAnalyzer {
    /// Attack-direction ambiguity is resolved per period; roles are direction-independent.
    /// Role comes from the long-axis distribution folded around midfield (GK/DEF sit near an
    /// end, MID central, FWD ranges the front third); side comes from the short-axis mean with
    /// per-period flip correction (periods are reflected so their long-axis means agree).
    public static func estimate(points: [TrackPoint], projector: FieldProjector,
                                events: [MatchEvent], playingIntervals: [DateInterval]) -> PositionEstimate {
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
                                    meanPoint: CGPoint(x: 0.5, y: 0.5), periodMeanPoints: [])
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
        if outerFraction > 0.6 && spreadX < 0.08 {
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
            periodMeanPoints: periodMeanPoints
        )
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
