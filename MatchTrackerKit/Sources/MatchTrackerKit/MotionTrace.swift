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

    /// What the last minute looked like. Nil without enough of it.
    public func reading(at date: Date) -> MotionReading? {
        let recent = levels(inLast: 60, before: date).sorted()
        guard !recent.isEmpty else { return nil }
        let median = recent[recent.count / 2]
        return median <= MotionReading.stillLevel ? .still : median >= MotionReading.playingLevel ? .playing : .moving
    }

    /// Whether there was a burst of running in the last minute, as even a goalkeeper has.
    public func isActive(at date: Date) -> Bool {
        (levels(inLast: 60, before: date).max() ?? 0) >= MotionReading.playingLevel
    }
}

/// The thresholds are published wrist figures (sitting under 0.1 g, walking around 0.3, running
/// 0.7 and up), set wide apart so that only the obvious is ever called.
public enum MotionReading: Sendable {
    case still, moving, playing

    static let stillLevel = 0.12
    static let playingLevel = 0.5
}
