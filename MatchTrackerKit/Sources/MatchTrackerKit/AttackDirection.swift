import Foundation
import CoreGraphics

// MARK: - Attack normalization
//
// Every pitch the app draws is portrait with the end the wearer's team attacks at the top. Teams
// switch ends at halftime, so the second half is turned around; without a halftime to trust, or in
// a kickabout where nobody switches, nothing is.

/// One moment of a match on that pitch.
public struct PitchSample: Equatable, Sendable {
    /// Seconds since the start of the match.
    public let t: TimeInterval
    /// 0 = left touchline, 1 = right, facing the attacking end.
    public let x: Double
    /// 0 = own goal line, 1 = the attacking end.
    public let y: Double
    public let speed: Double
    /// On the pitch, in play, and not standing about (`WaitingDetector`).
    public let onPitch: Bool
}

/// Share of on-pitch time spent in each third, adding to 1.
public struct PitchThirds: Equatable, Sendable {
    public let defensive: Double
    public let middle: Double
    public let attacking: Double
}

public struct AttackDirection: Equatable, Sendable {
    /// Whether the first half attacked the low end of the field's long axis.
    public let flipsAttack: Bool
    /// Nil when ends weren't switched, or nobody can tell when.
    public let halftime: DateInterval?
    /// False when the direction is a stable guess.
    public let isConfident: Bool

    public init(flipsAttack: Bool, halftime: DateInterval?, isConfident: Bool) {
        self.flipsAttack = flipsAttack
        self.halftime = halftime
        self.isConfident = isConfident
    }

    /// A field-normalized point (x along the long axis) on the portrait pitch.
    public func portrait(_ point: CGPoint, at date: Date) -> CGPoint {
        let isSecondHalf = halftime.map { date >= $0.start.addingTimeInterval($0.duration / 2) } ?? false
        return flipsAttack != isSecondHalf
            ? CGPoint(x: 1 - point.y, y: 1 - point.x)
            : CGPoint(x: point.y, y: point.x)
    }

    /// - Parameters:
    ///   - points: on-pitch, field-normalized positions over time.
    ///   - chosen: the wearer's own answer, which settles it.
    public static func resolve(points: [(date: Date, point: CGPoint)], format: MatchFormat,
                               halftime: DateInterval?, interval: DateInterval, events: [MatchEvent],
                               reportedPositions: [ReportedPosition]?, chosen: Bool?) -> AttackDirection {
        let halftime = format == .match ? halftime : nil
        // Two halves played in opposite directions with no idea where they meet: no answer fits both.
        let isMixed = !canBeTold(format: format, halftime: halftime, interval: interval)
        if let chosen {
            return AttackDirection(flipsAttack: chosen, halftime: halftime, isConfident: !isMixed)
        }
        let unflipped = AttackDirection(flipsAttack: false, halftime: halftime, isConfident: false)
        let forward = points.map { (date: $0.date, y: Double(unflipped.portrait($0.point, at: $0.date).y)) }
        let evidence = evidence(forward: forward, events: events, reportedPositions: reportedPositions)
        let isConfident = abs(evidence) >= confidentEvidence && !isMixed
        return AttackDirection(flipsAttack: isConfident && evidence < 0, halftime: halftime, isConfident: isConfident)
    }

    /// Whether being told would settle it. Not for two halves with no idea where they meet.
    public static func canBeTold(format: MatchFormat, halftime: DateInterval?, interval: DateInterval) -> Bool {
        format != .match || halftime != nil || interval.duration <= longestSingleHalf
    }

    private static let longestSingleHalf: TimeInterval = 55 * 60
    private static let confidentEvidence = 0.8

    /// Positive when the positions, as laid out, already attack upward. Scoring your own goal in
    /// one end says which end it was; so does where a forward or a defender spends the match.
    private static func evidence(forward: [(date: Date, y: Double)], events: [MatchEvent],
                                 reportedPositions: [ReportedPosition]?) -> Double {
        var total = 0.0
        for event in events {
            let weight: Double
            switch event.kind {
            case .goalMine: weight = 1
            case .assist: weight = 0.8
            case .goalForUs: weight = 0.3
            case .goalAgainstUs: weight = -0.3
            default: continue
            }
            // Goals are logged once the celebrating is over.
            let window = DateInterval(start: event.date.addingTimeInterval(-45), end: event.date)
            let ys = forward.filter { window.contains($0.date) }.map(\.y)
            guard !ys.isEmpty, abs(mean(ys) - 0.5) >= 0.15 else { continue }
            total += mean(ys) > 0.5 ? weight : -weight
        }

        let roles = Set((reportedPositions ?? []).map(\.role))
        let lean = mean(forward.map(\.y)) - 0.5
        if !forward.isEmpty, abs(lean) >= 0.06 {
            if roles == [.forward] {
                total += lean > 0 ? 1 : -1
            } else if !roles.isEmpty, roles.isSubset(of: [.defender, .goalkeeper]) {
                total += lean < 0 ? 1 : -1
            }
        }
        return total
    }
}

// MARK: - Standing about

/// Long spells in one spot: waiting for kickoff, a drink, a free kick being argued over. They say
/// nothing about where someone plays, and a minute of one outweighs ten of running.
public enum WaitingDetector {
    private static let minimumDuration: TimeInterval = 45
    private static let radiusMeters = 4.0
    /// Slower than this on average (m/s); above it, staying close is a duel, not a wait.
    private static let maximumSpeed = 0.8
    /// Fixes either side a position is averaged over, so GPS wander doesn't read as walking.
    private static let smoothing = 3

    /// Whether each sample of a time-ordered track is part of one.
    public static func isWaiting(_ track: [TrackPoint]) -> [Bool] {
        var waiting = [Bool](repeating: false, count: track.count)
        guard let reference = track.first?.coordinate else { return waiting }
        let frame = ENUFrame(reference: reference)
        let raw = track.map { frame.project($0.coordinate) }
        let positions = raw.indices.map { index -> CGPoint in
            let window = raw[max(0, index - smoothing)...min(raw.count - 1, index + smoothing)]
            return CGPoint(x: mean(window.map { Double($0.x) }), y: mean(window.map { Double($0.y) }))
        }
        let speeds = rawPointSpeeds(track)

        var start = 0
        while start < track.count {
            var total = CGPoint.zero
            var end = start
            while end < track.count {
                let count = CGFloat(end - start)
                if count > 0, hypot(Double(positions[end].x - total.x / count),
                                    Double(positions[end].y - total.y / count)) > radiusMeters { break }
                total = CGPoint(x: total.x + positions[end].x, y: total.y + positions[end].y)
                end += 1
            }
            let duration = track[end - 1].timestamp.timeIntervalSince(track[start].timestamp)
            if duration >= minimumDuration, mean(Array(speeds[start..<end])) <= maximumSpeed {
                for index in start..<end { waiting[index] = true }
                start = end
            } else {
                start += 1
            }
        }
        return waiting
    }
}

// MARK: - Portrait heat

/// Time on the pitch as a portrait grid: row-major, row 0 the attacking end, busiest cell 1.
public enum PortraitHeat {
    public static let columns = 24
    public static let rows = 36
    /// The size stored with every match (`MatchDigest.heat`).
    public static let thumbnailColumns = columns / 2
    public static let thumbnailRows = rows / 2

    /// `weights` are seconds spent at each point.
    static func compute(points: [(point: CGPoint, seconds: Double)]) -> [Float] {
        var cells = [Float](repeating: 0, count: columns * rows)
        for (point, seconds) in points {
            let column = min(max(Int(Double(point.x) * Double(columns)), 0), columns - 1)
            let row = min(max(Int((1 - Double(point.y)) * Double(rows)), 0), rows - 1)
            cells[row * columns + column] += Float(seconds)
        }
        return normalized(cells)
    }

    /// A thumbnail laid on its side, attacking right, for spaces wider than they're tall.
    public static func onItsSide(_ thumbnail: [Float]) -> HeatmapGrid? {
        guard thumbnail.count == thumbnailColumns * thumbnailRows else { return nil }
        var grid = HeatmapGrid(columns: thumbnailRows, rows: thumbnailColumns,
                               cells: Array(repeating: 0, count: thumbnail.count))
        for (index, value) in thumbnail.enumerated() {
            let (row, column) = index.quotientAndRemainder(dividingBy: thumbnailColumns)
            grid.cells[column * thumbnailRows + thumbnailRows - 1 - row] = Double(value)
        }
        return grid
    }

    static func thumbnail(_ heat: [Float]) -> [Float]? {
        guard heat.count == columns * rows else { return nil }
        var cells = [Float](repeating: 0, count: thumbnailColumns * thumbnailRows)
        for index in heat.indices {
            cells[index / columns / 2 * thumbnailColumns + index % columns / 2] += heat[index]
        }
        // Two decimals is finer than any screen shows, and keeps hundreds of these small on disk.
        return normalized(cells).map { ($0 * 100).rounded() / 100 }
    }

    /// Cell-wise average of same-sized grids, busiest cell 1.
    public static func average(_ grids: [[Float]]) -> [Float]? {
        guard let first = grids.first else { return nil }
        var total = [Float](repeating: 0, count: first.count)
        for grid in grids where grid.count == first.count {
            for index in grid.indices { total[index] += grid[index] }
        }
        return normalized(total)
    }

    private static func normalized(_ cells: [Float]) -> [Float] {
        guard let peak = cells.max(), peak > 0 else { return cells }
        return cells.map { $0 / peak }
    }
}
