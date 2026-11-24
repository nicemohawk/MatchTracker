import Foundation

/// How hard the wrist was moving through a match: one number every few seconds, small enough to
/// travel with the record. A benched wrist is nearly still; a playing one never is for long. It
/// tells a bench from a touchline, which GPS can't, and it works indoors.
public struct MotionTrace: Codable, Equatable, Sendable {
    public static let interval: TimeInterval = 5
    private static let missing: UInt8 = .max

    public let start: Date
    /// Hundredths of a g (RMS of acceleration without gravity) per interval.
    private var levels: [UInt8] = []

    public init(start: Date) {
        self.start = start
    }

    /// Intervals skipped since the last one (the app was relaunched) stay unknown.
    public mutating func append(_ level: Double, at date: Date) {
        let index = Int(date.timeIntervalSince(start) / Self.interval)
        guard index >= levels.count, index < 24 * 3600 / Int(Self.interval) else { return }
        levels.append(contentsOf: repeatElement(Self.missing, count: index - levels.count))
        levels.append(UInt8(min(max(level * 100, 0), 254)))
    }

    /// The levels known in the `window` before `date`. Empty with less than half of them known.
    public func levels(inLast window: TimeInterval, before date: Date) -> [Double] {
        let end = min(Int(date.timeIntervalSince(start) / Self.interval), levels.count)
        let wanted = Int(window / Self.interval)
        guard end > 0, wanted > 0 else { return [] }
        let known = levels[max(0, end - wanted)..<end].filter { $0 != Self.missing }
        return known.count * 2 >= wanted ? known.map { Double($0) / 100 } : []
    }

    /// The interval that ended at `date`. Nil when it's unknown.
    public func level(endingAt date: Date) -> Double? {
        let index = Int(date.timeIntervalSince(start) / Self.interval) - 1
        guard levels.indices.contains(index), levels[index] != Self.missing else { return nil }
        return Double(levels[index]) / 100
    }

    /// Whether the last minute held any running, on a wrist known to run at `runningLevel`.
    public func hasRun(before date: Date, runningLevel: Double) -> Bool {
        levels(inLast: 60, before: date).contains { $0 >= runningLevel }
    }
}

/// What running looks like on this wrist, learned from the moments GPS is sure about. Wrists differ
/// too much for a fixed number: arms swing, hold a drink, or get held still by a captain's armband.
public struct MotionCalibration: Sendable {
    private var walking: [Double] = []
    private var running: [Double] = []
    private static let memory = 200

    public init() {}

    mutating func learn(level: Double, speed: Double) {
        if (0.8...1.6).contains(speed) {
            walking = Array((walking + [level]).suffix(Self.memory))
        } else if speed >= 2.6 {
            running = Array((running + [level]).suffix(Self.memory))
        }
    }

    /// Nil until there's been enough of both to tell them apart.
    public var runningLevel: Double? {
        guard walking.count >= 20, running.count >= 10 else { return nil }
        let walk = walking.sorted()[walking.count / 2], run = running.sorted()[running.count / 2]
        return run > walk * 1.4 ? walk + 0.6 * (run - walk) : nil
    }

    func isRunning(_ level: Double?) -> Bool {
        guard let level, let runningLevel else { return false }
        return level >= runningLevel
    }
}
