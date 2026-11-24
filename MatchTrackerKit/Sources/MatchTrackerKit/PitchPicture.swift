import Foundation
import CoreGraphics

// MARK: - Pitch coordinates

/// A place on the pitch as the player sees it: `across` runs 0 (left touchline) to 1 (right),
/// `up` runs 0 (own goal line) to 1 (the goal being attacked).
public struct PitchPoint: Hashable, Codable, Sendable {
    public var across: Double
    public var up: Double

    public init(across: Double, up: Double) {
        self.across = across
        self.up = up
    }

    /// The same place seen by someone attacking the other way.
    public var turnedAround: PitchPoint { PitchPoint(across: 1 - across, up: 1 - up) }
}

/// The pitch's real dimensions, so markings are drawn to scale.
public struct PitchSize: Hashable, Codable, Sendable {
    public var lengthMeters: Double
    public var widthMeters: Double

    public init(lengthMeters: Double, widthMeters: Double) {
        self.lengthMeters = lengthMeters
        self.widthMeters = widthMeters
    }

    public static let standard = PitchSize(lengthMeters: 105, widthMeters: 68)

    /// Width over length, held to shapes a pitch can actually have.
    public var aspectRatio: Double {
        guard lengthMeters > 0, widthMeters > 0 else { return 68.0 / 105 }
        return min(max(widthMeters / lengthMeters, 0.45), 0.95)
    }

    /// 1 on a full-size pitch, where the laws fix the markings in meters. Smaller pitches shrink
    /// their boxes and circle with them.
    public var markingScale: Double {
        if lengthMeters >= 90, widthMeters >= 45 { return 1 }
        return min(1, max(0.25, min(lengthMeters / 105, widthMeters / 68)))
    }
}

// MARK: - Periods

public enum MatchPeriods {
    /// The stretches of play between breaks, from period events. One period spanning the whole
    /// match when none were logged or detected.
    public static func derive(events: [MatchEvent], matchStart: Date, matchEnd: Date) -> [DateInterval] {
        guard matchEnd > matchStart else { return [] }
        let boundaries = events
            .filter { $0.kind == .periodStart || $0.kind == .periodEnd }
            .filter { $0.date >= matchStart && $0.date <= matchEnd }
            .sorted { $0.date < $1.date }
        // A detected half-time arrives as an end then a start, so play is already under way.
        var openStart: Date? = boundaries.first?.kind == .periodStart ? nil : matchStart
        var periods: [DateInterval] = []
        for event in boundaries {
            if event.kind == .periodStart {
                if let start = openStart, event.date > start {
                    periods.append(DateInterval(start: start, end: event.date))
                }
                openStart = event.date
            } else if let start = openStart {
                if event.date > start { periods.append(DateInterval(start: start, end: event.date)) }
                openStart = nil
            }
        }
        if let start = openStart, matchEnd > start {
            periods.append(DateInterval(start: start, end: matchEnd))
        }
        // A few seconds between taps isn't a period.
        let real = periods.filter { $0.duration >= 60 }
        return real.isEmpty ? [DateInterval(start: matchStart, end: matchEnd)] : real
    }
}

// MARK: - Attack direction

/// Turns coordinates into `PitchPoint`s with the player always attacking up, swapping ends between
/// periods. Nothing records which way a team kicked, so the direction is inferred from where the
/// player scored and which way they sprinted; `isKnown` says whether that evidence was clear.
public struct AttackFrame: Sendable {
    public struct Period: Equatable, Sendable {
        public var interval: DateInterval
        /// Attacking toward the far end of the projector's long axis (normalized x = 1).
        public var attacksTowardFarEnd: Bool

        public init(interval: DateInterval, attacksTowardFarEnd: Bool) {
            self.interval = interval
            self.attacksTowardFarEnd = attacksTowardFarEnd
        }
    }

    public let periods: [Period]
    public let isKnown: Bool
    private let projector: FieldProjector

    public init(projector: FieldProjector, periods: [Period], isKnown: Bool) {
        self.projector = projector
        self.periods = periods
        self.isKnown = isKnown
    }

    /// How far (as a share of the pitch's length) evidence has to lean one way to be believed.
    private static let clearEvidence = 0.5

    public static func infer(track: [TrackPoint], runs: [RunSegment], projector: FieldProjector,
                             events: [MatchEvent], matchStart: Date, matchEnd: Date) -> AttackFrame {
        let intervals = MatchPeriods.derive(events: events, matchStart: matchStart, matchEnd: matchEnd)

        func normalizedX(at index: Int) -> Double? {
            guard track.indices.contains(index) else { return nil }
            return projector.normalizedPoint(for: track[index].coordinate).map { Double($0.x) }
        }
        func lean(in interval: DateInterval) -> Double {
            let sprintTravel = runs
                .filter { $0.intensity == .sprint && interval.contains($0.interval.start) }
                .reduce(0.0) { total, run in
                    guard let start = normalizedX(at: run.pointRange.lowerBound),
                          let end = normalizedX(at: run.pointRange.upperBound - 1) else { return total }
                    return total + (end - start)
                }
            // Scoring says far more about direction than any one sprint. Goals are tapped in late,
            // so look at the half-minute before the tap.
            let goalLean = events
                .filter { ($0.kind == .goalMine || $0.kind == .assist) && interval.contains($0.date) }
                .reduce(0.0) { total, event in
                    let before = track
                        .filter { $0.timestamp <= event.date && event.date.timeIntervalSince($0.timestamp) <= 30 }
                        .compactMap { projector.normalizedPoint(for: $0.coordinate).map { Double($0.x) } }
                    guard !before.isEmpty else { return total }
                    return total + 2 * (before.reduce(0, +) / Double(before.count) - 0.5)
                }
            return sprintTravel + goalLean
        }

        let leans = intervals.map(lean)
        // Two periods are two halves, and teams change ends: judge them together.
        if intervals.count == 2 {
            let together = leans[0] - leans[1]
            return AttackFrame(projector: projector, periods: [
                Period(interval: intervals[0], attacksTowardFarEnd: together >= 0),
                Period(interval: intervals[1], attacksTowardFarEnd: together < 0)
            ], isKnown: abs(together) >= clearEvidence)
        }
        return AttackFrame(
            projector: projector,
            periods: zip(intervals, leans).map { Period(interval: $0, attacksTowardFarEnd: $1 >= 0) },
            isKnown: !leans.isEmpty && leans.allSatisfy { abs($0) >= clearEvidence }
        )
    }

    /// Where on the pitch, clamped to the lines; nil when well outside them.
    public func point(for coordinate: Coordinate2D, at date: Date) -> PitchPoint? {
        guard let normalized = projector.normalizedPoint(for: coordinate) else { return nil }
        let along = min(max(Double(normalized.x), 0), 1)
        let side = min(max(Double(normalized.y), 0), 1)
        let period = periods.last { $0.interval.start <= date } ?? periods.first
        let point = PitchPoint(across: side, up: along)
        return period?.attacksTowardFarEnd == false ? point.turnedAround : point
    }
}

// MARK: - Heat

/// How long the player spent in each part of the pitch, attacking up. Row 0 is the attacking end,
/// so the grid reads like the picture.
public struct PitchHeat: Hashable, Codable, Sendable {
    public let columns: Int   // across
    public let rows: Int      // attacking end first
    public let values: [Float]

    public init(columns: Int, rows: Int, values: [Float]) {
        precondition(columns > 0 && rows > 0 && values.count == columns * rows)
        self.columns = columns
        self.rows = rows
        self.values = values
    }

    public static let empty = PitchHeat(columns: 1, rows: 1, values: [0])

    /// Roughly two-meter cells on a full pitch.
    public static let defaultColumns = 34
    public static let defaultRows = 52

    public var isEmpty: Bool { !values.contains { $0 > 0 } }

    /// Rotates a long-axis grid (columns along the pitch) to portrait.
    public init(_ grid: HeatmapGrid, attacksTowardFarEnd: Bool = true) {
        guard grid.columns > 0, grid.rows > 0, grid.cells.count == grid.columns * grid.rows else {
            self = .empty
            return
        }
        var values = [Float](repeating: 0, count: grid.columns * grid.rows)
        for row in 0..<grid.columns {
            for column in 0..<grid.rows {
                let value = attacksTowardFarEnd
                    ? grid[grid.columns - 1 - row, column]
                    : grid[row, grid.rows - 1 - column]
                values[row * grid.rows + column] = Float(value)
            }
        }
        self.init(columns: grid.rows, rows: grid.columns, values: values)
    }

    /// Time-weighted points.
    public init(samples: [(point: PitchPoint, seconds: Double)],
                columns: Int = PitchHeat.defaultColumns, rows: Int = PitchHeat.defaultRows) {
        var accumulator = Accumulator(columns: columns, rows: rows)
        for sample in samples { accumulator.add(sample.point, seconds: sample.seconds) }
        self = accumulator.heat
    }

    /// Builds heat up a fix at a time. Each fix is spread over its four nearest cells, so nothing
    /// depends on which side of a cell edge it happened to land.
    public struct Accumulator: Sendable {
        private let columns: Int
        private let rows: Int
        private var values: [Float]

        public init(columns: Int = PitchHeat.defaultColumns, rows: Int = PitchHeat.defaultRows) {
            self.columns = columns
            self.rows = rows
            values = [Float](repeating: 0, count: columns * rows)
        }

        public mutating func add(_ point: PitchPoint, seconds: Double) {
            guard seconds > 0, point.across.isFinite, point.up.isFinite else { return }
            let x = min(max(point.across, 0), 1) * Double(columns) - 0.5
            let y = (1 - min(max(point.up, 0), 1)) * Double(rows) - 0.5
            let column = Int(x.rounded(.down)), row = Int(y.rounded(.down))
            let fractionX = Float(x - Double(column)), fractionY = Float(y - Double(row))
            for (rowOffset, weightY) in [(0, 1 - fractionY), (1, fractionY)] {
                for (columnOffset, weightX) in [(0, 1 - fractionX), (1, fractionX)] {
                    let targetRow = min(max(row + rowOffset, 0), rows - 1)
                    let targetColumn = min(max(column + columnOffset, 0), columns - 1)
                    values[targetRow * columns + targetColumn] += Float(seconds) * weightX * weightY
                }
            }
        }

        public var heat: PitchHeat { PitchHeat(columns: columns, rows: rows, values: values) }
    }

    public var turnedAround: PitchHeat {
        PitchHeat(columns: columns, rows: rows, values: values.reversed())
    }

    /// The time-weighted middle of it all.
    public var average: PitchPoint? {
        var total = 0.0, across = 0.0, up = 0.0
        for row in 0..<rows {
            for column in 0..<columns {
                let value = Double(values[row * columns + column])
                total += value
                across += value * (Double(column) + 0.5) / Double(columns)
                up += value * (1 - (Double(row) + 0.5) / Double(rows))
            }
        }
        guard total > 0 else { return nil }
        return PitchPoint(across: across / total, up: up / total)
    }

    /// Share of time in each ninth, indexed `[third][lane]`: own goal to attacking goal, left to
    /// right. Cells straddling a boundary are split between the ninths either side of it.
    var zoneShares: [[Double]] {
        var zones = [[Double]](repeating: [0, 0, 0], count: 3)
        for row in 0..<rows {
            let rowSplit = Self.split(index: rows - 1 - row, count: rows)
            for column in 0..<columns {
                let value = Double(values[row * columns + column])
                guard value > 0 else { continue }
                let columnSplit = Self.split(index: column, count: columns)
                for third in 0..<3 {
                    for lane in 0..<3 { zones[third][lane] += value * rowSplit[third] * columnSplit[lane] }
                }
            }
        }
        let total = zones.joined().reduce(0, +)
        return total > 0 ? zones.map { $0.map { $0 / total } } : zones
    }

    private static func split(index: Int, count: Int) -> [Double] {
        let lower = Double(index) / Double(count), upper = Double(index + 1) / Double(count)
        return (0..<3).map { band in
            max(0, min(upper, Double(band + 1) / 3) - max(lower, Double(band) / 3)) / (upper - lower)
        }
    }
}

// MARK: - The picture, said out loud

/// The one sentence a pitch picture says to VoiceOver.
public enum PitchSentence {
    /// - Parameter directionIsKnown: When false, nothing is said about attacking or defending, or
    ///   about left or right, because either could be back to front.
    public static func describe(_ heat: PitchHeat, directionIsKnown: Bool = true,
                                goals: Int = 0, assists: Int = 0) -> String {
        guard !heat.isEmpty else { return "No positions recorded." }
        let zones = heat.zoneShares
        var sentence = directionIsKnown ? directed(zones) : undirected(zones)
        let moments = [goals > 0 ? count(goals, "goal") : nil,
                       assists > 0 ? count(assists, "assist") : nil].compactMap { $0 }
        if !moments.isEmpty { sentence += "; \(moments.joined(separator: " and ")) marked" }
        return sentence + "."
    }

    private static func thirds(_ zones: [[Double]]) -> [Double] { zones.map { $0.reduce(0, +) } }
    private static func lanes(_ zones: [[Double]]) -> [Double] {
        (0..<3).map { lane in zones.reduce(0) { $0 + $1[lane] } }
    }

    private static func directed(_ zones: [[Double]]) -> String {
        // Say the third that adds something: the attacking one, unless this was a defender's day.
        let thirds = thirds(zones)
        let isAttacking = thirds[2] >= thirds[0]
        let share = fraction(isAttacking ? thirds[2] : thirds[0])
        return "\(whereabouts(zones)); \(share) of the time in the \(isAttacking ? "attacking" : "defensive") third"
    }

    private static func undirected(_ zones: [[Double]]) -> String {
        if zones[1][1] >= 0.35 { return "Mostly central midfield" }
        let thirds = thirds(zones), lanes = lanes(zones)
        if thirds[1] >= 0.5 { return "Mostly midfield" }
        if max(thirds[0], thirds[2]) >= 0.5 { return "Mostly toward one end" }
        if max(lanes[0], lanes[2]) >= 0.5 { return "Mostly along one side" }
        return "All over the pitch"
    }

    private static func whereabouts(_ zones: [[Double]]) -> String {
        var best = (third: 1, lane: 1, share: -1.0)
        for third in 0..<3 {
            for lane in 0..<3 where zones[third][lane] > best.share { best = (third, lane, zones[third][lane]) }
        }
        let names = [["left back", "central defense", "right back"],
                     ["left midfield", "central midfield", "right midfield"],
                     ["the left wing", "up front through the middle", "the right wing"]]
        let name = names[best.third][best.lane]
        if best.share >= 0.35 { return "Mostly \(name)" }
        if thirds(zones)[best.third] >= 0.5 { return "Mostly \(["defense", "midfield", "up front"][best.third])" }
        if best.lane != 1, lanes(zones)[best.lane] >= 0.5 {
            return "Up and down the \(best.lane == 0 ? "left" : "right")"
        }
        return "All over the pitch, most often \(name)"
    }

    /// Words a person would use. Deliberately coarse: GPS doesn't know better than this.
    static func fraction(_ share: Double) -> String {
        switch share {
        case ..<0.03: return "hardly any"
        case ..<0.15: return "about a tenth"
        case ..<0.225: return "a fifth"
        case ..<0.29: return "a quarter"
        case ..<0.415: return "a third"
        case ..<0.585: return "half"
        case ..<0.71: return "two thirds"
        case ..<0.85: return "three quarters"
        default: return "nearly all"
        }
    }

    private static func count(_ number: Int, _ noun: String) -> String {
        let words = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        let word = words.indices.contains(number) ? words[number] : "\(number)"
        return "\(word) \(noun)\(number == 1 ? "" : "s")"
    }
}
