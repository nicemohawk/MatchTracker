import Foundation

// MARK: - Industry-standard soccer load metrics

/// Named physical-load metrics using the same validated definitions coaches know from dedicated
/// GPS platforms (STATSports Apex, Catapult One). This is deliberately the *credibility* layer that
/// sits alongside our own `WorkrateReport`: where the workrate score is a calibrated, format-aware
/// blend tuned to our product bands, these six numbers are the raw, named quantities a coach can
/// compare directly against a vest-pod readout.
///
/// ## Why the thresholds are absolute (not scaled by `MatchContext` / `pitchScale`)
/// `RunDetector`/`WorkrateAnalyzer` scale their speed thresholds by `pitchScale` so a hard burst on
/// a short turf pitch still reads as a "sprint" relative to that pitch. These metrics do the
/// opposite on purpose: they use the fixed FIFA/GPS-industry convention thresholds regardless of
/// pitch size, because a coach's whole reason for wanting *named* metrics is cross-context
/// comparison — "12 m/s and 240 m of sprint distance" must mean the same thing whether it was
/// recorded on a full pitch, a 5-a-side cage, or against a STATSports number from last season. A
/// pitch-relative "sprint" would quietly break that promise. Sprint distance measured on a small
/// pitch will simply, and correctly, be lower.
///
/// ## Definitions (industry convention)
/// - **Sprint distance** — distance covered at speed **> 7.0 m/s** (25.2 km/h).
/// - **High-speed running (HSR)** — distance covered in the **5.5…7.0 m/s** band (19.8–25.2 km/h).
/// - **Accelerations** — discrete efforts exceeding **+3.0 m/s²** sustained for **≥ 0.5 s**.
/// - **Decelerations** — discrete efforts below **−3.0 m/s²** sustained for **≥ 0.5 s**.
/// - **Distance per minute** — total on-pitch distance ÷ on-pitch minutes (0 with no on-pitch time).
/// - **Top speed** — peak instantaneous speed, with teleport/glitch outliers rejected.
///
/// All distance and speed accumulation is restricted to `playingIntervals` (bench time excluded).
/// An empty `playingIntervals` means "no substitution data" and is treated as the whole track being
/// on-pitch, matching the convention used elsewhere in the Kit.
public struct SoccerLoadMetrics: Codable, Sendable, Equatable {
    /// Distance (m) covered at speed > 7.0 m/s (25.2 km/h).
    public let sprintDistanceMeters: Double
    /// Distance (m) covered in the 5.5…7.0 m/s band (19.8–25.2 km/h).
    public let highSpeedRunningMeters: Double
    /// Discrete efforts exceeding +3.0 m/s² for ≥ 0.5 s.
    public let accelerationCount: Int
    /// Discrete efforts below −3.0 m/s² for ≥ 0.5 s.
    public let decelerationCount: Int
    /// Total on-pitch distance ÷ on-pitch minutes (0 if no on-pitch time).
    public let distancePerMinuteMeters: Double
    /// Peak instantaneous speed (m/s), outliers rejected.
    public let topSpeedMetersPerSecond: Double

    public init(sprintDistanceMeters: Double, highSpeedRunningMeters: Double,
                accelerationCount: Int, decelerationCount: Int,
                distancePerMinuteMeters: Double, topSpeedMetersPerSecond: Double) {
        self.sprintDistanceMeters = sprintDistanceMeters
        self.highSpeedRunningMeters = highSpeedRunningMeters
        self.accelerationCount = accelerationCount
        self.decelerationCount = decelerationCount
        self.distancePerMinuteMeters = distancePerMinuteMeters
        self.topSpeedMetersPerSecond = topSpeedMetersPerSecond
    }

    /// The all-zero metrics, returned for tracks too short to measure (empty or single-point).
    public static let zero = SoccerLoadMetrics(
        sprintDistanceMeters: 0, highSpeedRunningMeters: 0,
        accelerationCount: 0, decelerationCount: 0,
        distancePerMinuteMeters: 0, topSpeedMetersPerSecond: 0)

    // MARK: - Absolute FIFA/GPS-industry thresholds (never pitch-scaled — see type doc)

    /// Speed threshold (m/s) at/above which distance counts as sprinting. Strictly greater-than.
    public static let sprintSpeedMetersPerSecond = 7.0
    /// Lower bound (m/s) of the high-speed-running band; the upper bound is `sprintSpeedMetersPerSecond`.
    public static let highSpeedRunningLowerMetersPerSecond = 5.5
    /// Acceleration magnitude (m/s²) an effort must exceed to be counted.
    public static let accelerationThresholdMetersPerSecondSquared = 3.0
    /// Minimum time (s) an effort must stay past threshold to count (rejects single-sample spikes).
    public static let minimumEffortSeconds = 0.5
    /// Minimum time (s) between two counted efforts of the same sign (debounce; one burst == one effort).
    public static let effortDebounceSeconds = 2.0
    /// Speed (m/s) above which an instantaneous value is treated as a GPS glitch/teleport and rejected.
    /// Comfortably above elite human top speed (~12.4 m/s), so real play is never clipped.
    public static let outlierSpeedCapMetersPerSecond = 12.0
    /// Half-width (s) of the moving-average window applied to speed before differentiating for
    /// acceleration. ~1 s total window keeps GPS jitter from manufacturing phantom accel spikes.
    private static let speedSmoothingHalfWindowSeconds = 0.5

    /// Computes the load metrics for a GPS track, restricting accumulation to `playingIntervals`.
    /// An empty `playingIntervals` is treated as "whole track on-pitch".
    public static func compute(track: [TrackPoint],
                               playingIntervals: [DateInterval]) -> SoccerLoadMetrics {
        // Sort, and drop fixes too loose to trust (one of the two teleport-outlier guards).
        let points = track
            .sorted { $0.timestamp < $1.timestamp }
            .filter { $0.horizontalAccuracy <= TrackPoint.maximumUsableHorizontalAccuracy }
        guard points.count >= 2 else { return .zero }

        let timestamps = points.map(\.timestamp)
        let intervals = playingIntervals
        func onPitch(_ date: Date) -> Bool { intervals.isEmpty || isWithin(date, intervals: intervals) }

        // Per-point instantaneous speed with outliers rejected, then a ~1 s moving average used for
        // band classification and acceleration (the second teleport guard lives in the loops below).
        let instantaneous = sanitizedSpeeds(points)
        let smoothed = movingAverage(instantaneous, timestamps: timestamps,
                                     halfWindow: speedSmoothingHalfWindowSeconds)

        // Distance accumulation (on-pitch steps only), split into sprint / HSR bands.
        var sprintDistance = 0.0
        var highSpeedDistance = 0.0
        var totalDistance = 0.0
        for index in 0..<(points.count - 1) {
            guard onPitch(timestamps[index]), onPitch(timestamps[index + 1]) else { continue }
            let dt = timestamps[index + 1].timeIntervalSince(timestamps[index])
            guard dt > 0 else { continue }
            let stepDistance = haversineMeters(points[index].coordinate, points[index + 1].coordinate)
            // Teleport guard: a step whose implied speed exceeds the cap is a GPS jump, not travel.
            guard stepDistance / dt <= outlierSpeedCapMetersPerSecond else { continue }

            totalDistance += stepDistance
            // A point's speed reflects the motion arriving at it (speed[i] ≈ dist(i-1,i)/dt), so the
            // step ending at `index + 1` is classified by that point's smoothed speed.
            let stepSpeed = smoothed[index + 1]
            if stepSpeed > sprintSpeedMetersPerSecond {
                sprintDistance += stepDistance
            } else if stepSpeed >= highSpeedRunningLowerMetersPerSecond {
                highSpeedDistance += stepDistance
            }
        }

        // Top speed over on-pitch points (instantaneous, already outlier-capped).
        var topSpeed = 0.0
        for index in points.indices where onPitch(timestamps[index]) {
            topSpeed = max(topSpeed, instantaneous[index])
        }

        // Discrete, debounced accel/decel efforts from the smoothed speed signal.
        let accelerationCount = countEfforts(smoothed: smoothed, timestamps: timestamps,
                                             onPitch: onPitch, rising: true)
        let decelerationCount = countEfforts(smoothed: smoothed, timestamps: timestamps,
                                             onPitch: onPitch, rising: false)

        // Distance per on-pitch minute.
        let onPitchSeconds: TimeInterval = intervals.isEmpty
            ? timestamps[timestamps.count - 1].timeIntervalSince(timestamps[0])
            : intervals.reduce(0) { $0 + $1.duration }
        let distancePerMinute = onPitchSeconds > 0 ? totalDistance / (onPitchSeconds / 60) : 0

        return SoccerLoadMetrics(
            sprintDistanceMeters: sprintDistance,
            highSpeedRunningMeters: highSpeedDistance,
            accelerationCount: accelerationCount,
            decelerationCount: decelerationCount,
            distancePerMinuteMeters: distancePerMinute,
            topSpeedMetersPerSecond: topSpeed)
    }

    // MARK: - Speed derivation

    /// Per-point instantaneous speed (reported when valid, else GPS-derived — the same basis as
    /// `RunDetector`/`WorkrateAnalyzer`), with outliers above the sanity cap discarded and refilled
    /// from the nearest valid neighbour so a single glitch neither sets top speed nor spikes accel.
    private static func sanitizedSpeeds(_ points: [TrackPoint]) -> [Double] {
        var speeds = rawPointSpeeds(points)
        // Replace out-of-range samples with a sentinel, then forward/backward fill from valid values.
        for index in speeds.indices where speeds[index] < 0 || speeds[index] > outlierSpeedCapMetersPerSecond {
            speeds[index] = .nan
        }
        var lastValid: Double?
        for index in speeds.indices {
            if speeds[index].isNaN {
                if let carry = lastValid { speeds[index] = carry }
            } else {
                lastValid = speeds[index]
            }
        }
        // Any leading sentinels had no prior valid value; fill them from the first valid one.
        if let firstValid = speeds.first(where: { !$0.isNaN }) {
            for index in speeds.indices {
                if speeds[index].isNaN { speeds[index] = firstValid } else { break }
            }
        } else {
            return [Double](repeating: 0, count: speeds.count)
        }
        return speeds
    }

    /// Time-windowed moving average (half-window `halfWindow` seconds each side). Rate-independent,
    /// so it smooths whether GPS arrives at 1 Hz or faster; a single-sample spike is averaged down
    /// below the accel threshold before differentiation.
    private static func movingAverage(_ values: [Double], timestamps: [Date],
                                      halfWindow: TimeInterval) -> [Double] {
        guard values.count >= 3 else { return values }
        var result = values
        for index in values.indices {
            var sum = values[index]
            var count = 1
            var back = index - 1
            while back >= 0 && timestamps[index].timeIntervalSince(timestamps[back]) <= halfWindow {
                sum += values[back]; count += 1; back -= 1
            }
            var forward = index + 1
            while forward < values.count && timestamps[forward].timeIntervalSince(timestamps[index]) <= halfWindow {
                sum += values[forward]; count += 1; forward += 1
            }
            result[index] = sum / Double(count)
        }
        return result
    }

    // MARK: - Effort detection

    /// Counts discrete acceleration (`rising == true`) or deceleration efforts. An effort begins
    /// when the smoothed acceleration crosses the ±3 m/s² threshold and ends when it drops back
    /// below; it counts only if it stayed past threshold for ≥ `minimumEffortSeconds`, and only if
    /// it began at least `effortDebounceSeconds` after the previous counted effort of the same sign
    /// (so one burst can't be double-counted through brief flicker).
    private static func countEfforts(smoothed: [Double], timestamps: [Date],
                                     onPitch: (Date) -> Bool, rising: Bool) -> Int {
        guard smoothed.count >= 2 else { return 0 }
        let threshold = accelerationThresholdMetersPerSecondSquared
        let epsilon = 1e-6

        var count = 0
        var inEffort = false
        var effortStart = Date.distantPast
        var sustained: TimeInterval = 0
        var lastCountedEnd: Date?

        func finalize(endedAt end: Date) {
            defer { inEffort = false; sustained = 0 }
            guard inEffort, sustained >= minimumEffortSeconds - epsilon else { return }
            if let last = lastCountedEnd,
               effortStart.timeIntervalSince(last) < effortDebounceSeconds - epsilon {
                return   // too close to the previous counted effort of this sign — debounced
            }
            count += 1
            lastCountedEnd = end
        }

        for index in 1..<smoothed.count {
            let dt = timestamps[index].timeIntervalSince(timestamps[index - 1])
            guard dt > 0 else { continue }
            let acceleration = (smoothed[index] - smoothed[index - 1]) / dt
            let past = rising ? acceleration >= threshold : acceleration <= -threshold
            let bothOnPitch = onPitch(timestamps[index - 1]) && onPitch(timestamps[index])
            if past && bothOnPitch {
                if !inEffort { inEffort = true; effortStart = timestamps[index - 1] }
                sustained += dt
            } else {
                finalize(endedAt: timestamps[index - 1])
            }
        }
        finalize(endedAt: timestamps[timestamps.count - 1])
        return count
    }
}
