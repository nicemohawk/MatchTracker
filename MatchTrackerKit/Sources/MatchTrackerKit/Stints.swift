import Foundation

/// When somebody was playing, told by their heart alone: indoors, where there's no GPS, subs roll
/// every few minutes and one booking often holds several games.
///
/// A heart follows play by about a minute, quicker up than down. Undoing that lag gives how hard it
/// was being asked to work, which falls into two levels, on and off.
public struct Stints: Equatable, Sendable {
    /// On the court, oldest first.
    public let playing: [DateInterval]
    /// How far the heart rate fell in the first minute of each rest.
    public let recoveries: [Double]
    /// The whole session in equal slices: 0 off, and up to 1 the harder it was.
    public let strip: [Float]

    public static let stripCount = 48
    private static let step: TimeInterval = 5
    /// Shorter than this is a throw-in or a breather, not a change.
    private static let shortest: TimeInterval = 75
    /// A longer rest than this is between games.
    private static let betweenGames: TimeInterval = 8 * 60
    /// On and off less than this apart (bpm) aren't two things.
    private static let smallestDifference = 22.0

    public var played: TimeInterval { playing.reduce(0) { $0 + $1.duration } }
    public var longest: TimeInterval { playing.map(\.duration).max() ?? 0 }

    /// The usual fall in a minute. Nil without two rests to say what's usual.
    public var recovery: Double? {
        recoveries.count >= 2 ? recoveries.sorted()[recoveries.count / 2] : nil
    }

    /// Each game from its first stint to its last.
    public var games: [[DateInterval]] {
        playing.reduce(into: []) { games, stint in
            if let last = games.last?.last, stint.start.timeIntervalSince(last.end) < Self.betweenGames {
                games[games.count - 1].append(stint)
            } else {
                games.append([stint])
            }
        }
    }

    /// Nil when the heart rate is too sparse to follow, or never fell far enough to have been resting.
    public static func detect(heartRate: [HeartRateSample], in interval: DateInterval) -> Stints? {
        let samples = heartRate.filter { interval.contains($0.date) }.sorted { $0.date < $1.date }
        let count = Int(interval.duration / step)
        guard count >= 60, Double(samples.count) * 15 >= interval.duration else { return nil }
        let rates = resampled(samples, from: interval.start, count: count)
        let demand = demand(rates)
        guard let levels = levels(of: demand), levels.high - levels.low >= smallestDifference else { return nil }

        let isOn = withoutBlips(path(demand, levels))
        let playing = runs(of: true, in: isOn).map { span(of: $0, from: interval.start) }
        guard !playing.isEmpty else { return nil }
        let smooth = smoothed(rates, radius: 2)
        let recoveries = runs(of: false, in: isOn).filter { $0.lowerBound > 0 && $0.count >= 14 }
            .map { smooth[$0.lowerBound] - smooth[min($0.lowerBound + 12, count - 1)] }
        let strip = (0..<stripCount).map { slice -> Float in
            let range = (slice * count / stripCount)..<max(slice * count / stripCount + 1, (slice + 1) * count / stripCount)
            let on = range.filter { isOn[$0] }
            guard on.count * 2 >= range.count else { return 0 }
            let hardness = mean(on.map { (demand[$0] - levels.low) / (levels.high - levels.low) })
            return Float(min(max(hardness, 0.35), 1.15) / 1.15)
        }
        return Stints(playing: playing, recoveries: recoveries, strip: strip)
    }

    // MARK: Steps

    private static func resampled(_ samples: [HeartRateSample], from start: Date, count: Int) -> [Double] {
        var index = 0
        return (0..<count).map { position in
            let date = start.addingTimeInterval(Double(position) * step)
            while index + 1 < samples.count, samples[index + 1].date <= date { index += 1 }
            guard index + 1 < samples.count, samples[index].date <= date else { return samples[index].bpm }
            let gap = samples[index + 1].date.timeIntervalSince(samples[index].date)
            let share = gap > 0 ? date.timeIntervalSince(samples[index].date) / gap : 0
            return samples[index].bpm + (samples[index + 1].bpm - samples[index].bpm) * share
        }
    }

    private static func smoothed(_ values: [Double], radius: Int) -> [Double] {
        values.indices.map { mean(Array(values[max(0, $0 - radius)...min(values.count - 1, $0 + radius)])) }
    }

    /// What the heart was heading for: where it is, plus how fast it's moving times its lag.
    private static func demand(_ rates: [Double]) -> [Double] {
        let smooth = smoothed(rates, radius: 3)
        return smoothed(smooth.indices.map { index in
            let from = max(0, index - 3), to = min(smooth.count - 1, index + 3)
            let slope = (smooth[to] - smooth[from]) / (Double(to - from) * step)
            return smooth[index] + slope * (slope > 0 ? 40 : 70)
        }, radius: 2)
    }

    private static func levels(of demand: [Double]) -> (low: Double, high: Double)? {
        let sorted = demand.sorted()
        var low = sorted[sorted.count * 15 / 100], high = sorted[sorted.count * 85 / 100]
        for _ in 0..<20 {
            let middle = (low + high) / 2
            let below = demand.filter { $0 < middle }, above = demand.filter { $0 >= middle }
            guard !below.isEmpty, !above.isEmpty else { return nil }
            (low, high) = (mean(below), mean(above))
        }
        return (low, high)
    }

    /// The likeliest story of on and off, where every change has to earn its keep.
    private static func path(_ demand: [Double], _ levels: (low: Double, high: Double)) -> [Bool] {
        let spread = (levels.high - levels.low) / 2.2, changing = 6.0
        var on = 0.0, off = 0.0
        var cameFromOn: [(on: Bool, off: Bool)] = []
        for value in demand {
            let likelier = (pow(value - levels.low, 2) - pow(value - levels.high, 2)) / (2 * spread * spread)
            let weight = min(max(likelier, -3), 3) / 2
            cameFromOn.append((on: on >= off - changing, off: on - changing > off))
            (on, off) = (max(on, off - changing) + weight, max(off, on - changing) - weight)
        }
        var isOn = on > off
        var path: [Bool] = []
        for step in cameFromOn.reversed() {
            path.append(isOn)
            isOn = isOn ? step.on : step.off
        }
        return path.reversed()
    }

    private static func withoutBlips(_ isOn: [Bool]) -> [Bool] {
        var result = isOn
        let shortest = Int(Self.shortest / step)
        for isPlaying in [false, true] {
            for run in runs(of: isPlaying, in: result)
            where run.count < shortest && run.lowerBound > 0 && run.upperBound < result.count {
                for index in run { result[index] = !isPlaying }
            }
        }
        return result
    }

    private static func runs(of value: Bool, in values: [Bool]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for index in values.indices {
            if values[index] == value {
                start = start ?? index
            } else if let begun = start {
                runs.append(begun..<index)
                start = nil
            }
        }
        if let start { runs.append(start..<values.count) }
        return runs
    }

    private static func span(of run: Range<Int>, from start: Date) -> DateInterval {
        DateInterval(start: start.addingTimeInterval(Double(run.lowerBound) * step), duration: Double(run.count) * step)
    }
}

/// Where both were true.
func intersection(_ first: [DateInterval], _ second: [DateInterval]) -> [DateInterval] {
    first.flatMap { interval in second.compactMap { interval.intersection(with: $0) } }
        .filter { $0.duration > 0 }
        .sorted { $0.start < $1.start }
}
