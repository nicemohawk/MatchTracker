import Foundation
import CoreGraphics

// MARK: - Sensor-fusion track smoothing

/// A device-heading sample (from `CMDeviceMotion` on the watch). Only the compass heading of the
/// long axis is carried; the fuser uses it to bend dead-reckoned interpolation through GPS gaps.
public struct HeadingSample: Codable, Sendable {
    public var timestamp: Date
    public var headingDegrees: Double     // compass bearing 0..<360

    public init(timestamp: Date, headingDegrees: Double) {
        self.timestamp = timestamp
        self.headingDegrees = headingDegrees
    }
}

public enum TrackSmoother {
    /// Longest step (seconds) that is treated as continuous GPS; longer gaps get 1 Hz
    /// dead-reckoned fill.
    private static let gapThreshold = 2.0

    /// Fuses GPS points with device-heading samples:
    ///   1. accuracy-weighted 3-point smoothing of the raw fixes (jitter reduction), then
    ///   2. for GPS gaps > 2 s, insert 1 Hz points via constant-velocity dead reckoning bent by
    ///      the heading samples (endpoint-corrected so the fill still lands on the next fix).
    /// Output is timestamp-sorted with a point count >= the input. Empty `headings` is a strict
    /// no-op: the input is returned unchanged.
    public static func fuse(track: [TrackPoint], headings: [HeadingSample]) -> [TrackPoint] {
        guard !headings.isEmpty else { return track }             // strict no-op
        guard track.count > 1 else { return track.sorted { $0.timestamp < $1.timestamp } }

        let ordered = track.sorted { $0.timestamp < $1.timestamp }
        let sortedHeadings = headings.sorted { $0.timestamp < $1.timestamp }
        let smoothed = accuracyWeightedSmooth(ordered)

        var output: [TrackPoint] = []
        output.reserveCapacity(smoothed.count)
        for index in smoothed.indices {
            let point = smoothed[index]
            output.append(point)
            guard index < smoothed.count - 1 else { continue }
            let next = smoothed[index + 1]
            let dt = next.timestamp.timeIntervalSince(point.timestamp)
            guard dt > gapThreshold else { continue }
            output.append(contentsOf: deadReckon(from: point, to: next, headings: sortedHeadings))
        }
        return output
    }

    // MARK: - Accuracy-weighted 3-point smoothing

    /// Each interior fix is replaced by an inverse-accuracy-weighted average of itself and its two
    /// neighbours (better fixes carry more weight). Endpoints are left untouched. Timestamps,
    /// speed, course and accuracy are preserved; only the coordinate is smoothed.
    private static func accuracyWeightedSmooth(_ track: [TrackPoint]) -> [TrackPoint] {
        guard track.count >= 3 else { return track }
        var result = track
        for index in 1..<(track.count - 1) {
            let previous = track[index - 1]
            let current = track[index]
            let next = track[index + 1]

            let weightPrevious = weight(for: previous.horizontalAccuracy)
            let weightCurrent = weight(for: current.horizontalAccuracy)
            let weightNext = weight(for: next.horizontalAccuracy)
            let total = weightPrevious + weightCurrent + weightNext
            guard total > 0 else { continue }

            let latitude = (previous.coordinate.latitude * weightPrevious
                            + current.coordinate.latitude * weightCurrent
                            + next.coordinate.latitude * weightNext) / total
            let longitude = (previous.coordinate.longitude * weightPrevious
                             + current.coordinate.longitude * weightCurrent
                             + next.coordinate.longitude * weightNext) / total
            result[index].coordinate = Coordinate2D(latitude: latitude, longitude: longitude)
        }
        return result
    }

    /// Inverse-accuracy weight: tighter fixes (smaller horizontalAccuracy) weigh more. A floor of
    /// 1 m avoids divide-by-zero and keeps perfect fixes from dominating entirely.
    private static func weight(for horizontalAccuracy: Double) -> Double {
        1.0 / max(horizontalAccuracy, 1.0)
    }

    // MARK: - Heading-bent dead reckoning

    /// 1 Hz interpolation from `start` to `end`. A constant-velocity dead-reckoned path is stepped
    /// each second along the heading in force at that instant, then linearly corrected so it still
    /// terminates at `end` (distributing the accumulated drift). The straight-line midpoints are
    /// used when no heading covers the gap. Returns only the interior fill points.
    private static func deadReckon(from start: TrackPoint, to end: TrackPoint, headings: [HeadingSample]) -> [TrackPoint] {
        let dt = end.timestamp.timeIntervalSince(start.timestamp)
        let steps = Int(dt.rounded(.down))
        guard steps >= 2 else { return [] }        // need at least one strictly-interior second

        let frame = ENUFrame(reference: start.coordinate)
        let startLocal = frame.project(start.coordinate)
        let endLocal = frame.project(end.coordinate)
        let totalDistance = hypot(Double(endLocal.x - startLocal.x), Double(endLocal.y - startLocal.y))
        let speed = totalDistance / dt

        // Dead-reckon forward from start, one second at a time, along the active heading.
        var deadReckoned: [CGPoint] = [startLocal]
        var cursor = startLocal
        for step in 1...steps {
            let sampleTime = start.timestamp.addingTimeInterval(Double(step))
            let heading = headingDegrees(at: sampleTime, headings: headings)
            let radians = heading * .pi / 180
            // Compass bearing -> ENU unit vector (east = sin, north = cos).
            cursor = CGPoint(x: cursor.x + CGFloat(speed * sin(radians)),
                             y: cursor.y + CGFloat(speed * cos(radians)))
            deadReckoned.append(cursor)
        }

        // Distribute the endpoint drift linearly so the fill still lands on `end`.
        let driftX = endLocal.x - deadReckoned[steps].x
        let driftY = endLocal.y - deadReckoned[steps].y

        var fill: [TrackPoint] = []
        for step in 1..<steps {                    // interior seconds only
            let correction = CGFloat(Double(step) / Double(steps))
            let corrected = CGPoint(x: deadReckoned[step].x + driftX * correction,
                                    y: deadReckoned[step].y + driftY * correction)
            let coordinate = frame.unproject(corrected)
            let timestamp = start.timestamp.addingTimeInterval(Double(step))
            let course = headingDegrees(at: timestamp, headings: headings)
            fill.append(TrackPoint(
                coordinate: coordinate,
                timestamp: timestamp,
                speedMetersPerSecond: speed,
                courseDegrees: course,
                // Interpolated fixes are synthetic; flag them with the worse of the two anchors.
                horizontalAccuracy: max(start.horizontalAccuracy, end.horizontalAccuracy)
            ))
        }
        return fill
    }

    /// Nearest heading sample to `time` (samples are pre-sorted); falls back to the last known
    /// heading, then 0.
    private static func headingDegrees(at time: Date, headings: [HeadingSample]) -> Double {
        guard let first = headings.first else { return 0 }
        var best = first
        var bestGap = abs(first.timestamp.timeIntervalSince(time))
        for sample in headings.dropFirst() {
            let gap = abs(sample.timestamp.timeIntervalSince(time))
            if gap < bestGap {
                bestGap = gap
                best = sample
            }
        }
        return best.headingDegrees
    }
}
