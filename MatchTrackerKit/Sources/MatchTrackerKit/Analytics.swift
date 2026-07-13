import Foundation
import CoreGraphics

// MARK: - Analytics

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

    /// Bins time-weighted samples. Only points inside playingIntervals count (nil = all).
    public static func compute(points: [TrackPoint], projector: FieldProjector,
                               columns: Int, rows: Int,
                               playingIntervals: [DateInterval]?) -> HeatmapGrid {
        // STUB: empty grid of the requested dimensions.
        let count = max(0, columns) * max(0, rows)
        return HeatmapGrid(columns: columns, rows: rows, cells: Array(repeating: 0, count: count))
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
        self.jogThreshold = 2.0
        self.runThreshold = 4.0
        self.sprintThreshold = 5.5
        self.minimumDuration = 2.0
        self.mergeGap = 1.5
    }
}

public enum RunDetector {
    /// Speed-threshold segmentation with hysteresis + gap merging. Uses GPS-derived speed
    /// (point-to-point) when speedMetersPerSecond invalid.
    public static func detectRuns(in track: [TrackPoint], configuration: RunDetectorConfiguration) -> [RunSegment] {
        // STUB: no runs detected yet.
        return []
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
    public static func analyze(track: [TrackPoint], runs: [RunSegment],
                               playingIntervals: [DateInterval]) -> WorkrateReport {
        // STUB: empty report.
        return WorkrateReport()
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
    public static func estimate(points: [TrackPoint], projector: FieldProjector,
                                events: [MatchEvent], playingIntervals: [DateInterval]) -> PositionEstimate {
        // STUB: neutral midfielder/center estimate with zero confidence.
        return PositionEstimate(
            role: .midfielder,
            side: .center,
            confidence: 0,
            meanPoint: CGPoint(x: 0.5, y: 0.5),
            periodMeanPoints: []
        )
    }
}
