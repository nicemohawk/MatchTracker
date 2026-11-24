import Foundation

/// Maps a short video onto a whole match: races through the ordinary minutes, lingers on the
/// moments worth seeing, and skips half-time. Pure and deterministic.
public struct ReplayTimeline: Sendable {
    public struct Moment: Equatable, Sendable {
        public var interval: DateInterval
        /// Screen seconds this moment gets on top of the time it would pass in anyway.
        public var extraScreenSeconds: Double

        public init(interval: DateInterval, extraScreenSeconds: Double) {
            self.interval = interval
            self.extraScreenSeconds = extraScreenSeconds
        }
    }

    /// One period's slice of the video.
    public struct Chapter: Equatable, Sendable {
        public let period: DateInterval
        public let screen: ClosedRange<Double>
        /// Play seconds before this chapter, so the clock carries on through half-time.
        public let playSecondsBefore: Double
        /// Cumulative screen share at each step through the period, 0...1.
        fileprivate let cumulative: [Double]
    }

    public enum Phase: Equatable, Sendable {
        case opening(progress: Double)
        case playing(chapter: Int)
        /// Between periods.
        case pause(after: Int, progress: Double)
        case closing(progress: Double)
    }

    public let chapters: [Chapter]
    public let duration: Double

    private static let stepsPerPeriod = 2400

    /// - Parameters:
    ///   - playing: When the player was on the pitch; time outside rushes by. Empty means always.
    ///   - opening: Screen seconds before kick-off.
    ///   - pause: Screen seconds between periods.
    ///   - closing: Screen seconds after the final whistle.
    public init(periods: [DateInterval], playing: [DateInterval], moments: [Moment],
                duration: Double = 15, opening: Double = 1.4, pause: Double = 0.9, closing: Double = 2.8) {
        self.duration = duration
        let real = periods.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
        let total = real.reduce(0) { $0 + $1.duration }
        guard total > 0 else {
            chapters = []
            return
        }
        // Many short periods (pickup) can't each have a full pause.
        let gaps = Double(real.count - 1)
        let available = duration - opening - closing
        let pauseEach = gaps > 0 ? min(pause, available * 0.2 / gaps) : 0
        let playScreen = available - pauseEach * gaps
        // Lingering never takes more than half of it: the match still has to fit.
        let shown = moments.filter { moment in real.contains { $0.contains(moment.interval.start) } }
        let wanted = shown.reduce(0) { $0 + $1.extraScreenSeconds }
        let momentScale = wanted > playScreen * 0.5 ? playScreen * 0.5 / wanted : 1
        let base = playScreen - wanted * momentScale

        var cursor = opening
        var played = 0.0
        var built: [Chapter] = []
        for (index, period) in real.enumerated() {
            let step = period.duration / Double(Self.stepsPerPeriod)
            var weights = (0..<Self.stepsPerPeriod).map { position -> Double in
                let date = period.start.addingTimeInterval((Double(position) + 0.5) * step)
                // Bench time rushes by rather than being shown at length or cut to a jump.
                return playing.isEmpty || isWithin(date, intervals: playing) ? 1 : 0.15
            }
            let weightTotal = weights.reduce(0, +)
            let baseScreen = base * period.duration / total
            weights = weights.map { $0 / weightTotal * baseScreen }

            for moment in shown where real.firstIndex(where: { $0.contains(moment.interval.start) }) == index {
                // A raised-cosine bump eases the clock into the moment and out again.
                let halfWidth = max(moment.interval.duration, step * 8)
                let center = moment.interval.start.timeIntervalSince(period.start) + moment.interval.duration / 2
                let bump = (0..<Self.stepsPerPeriod).map { position -> Double in
                    let offset = ((Double(position) + 0.5) * step - center) / halfWidth
                    return abs(offset) < 1 ? (1 + cos(.pi * offset)) / 2 : 0
                }
                let bumpTotal = bump.reduce(0, +)
                guard bumpTotal > 0 else { continue }
                let scale = moment.extraScreenSeconds * momentScale / bumpTotal
                for position in weights.indices { weights[position] += bump[position] * scale }
            }

            let screenSeconds = weights.reduce(0, +)
            var cumulative = [0.0]
            cumulative.reserveCapacity(weights.count + 1)
            for weight in weights { cumulative.append(cumulative[cumulative.count - 1] + weight / screenSeconds) }
            built.append(Chapter(period: period, screen: cursor...(cursor + screenSeconds),
                                 playSecondsBefore: played, cumulative: cumulative))
            cursor += screenSeconds + (index < real.count - 1 ? pauseEach : 0)
            played += period.duration
        }
        chapters = built
    }

    public func phase(at screenTime: Double) -> Phase {
        guard let first = chapters.first, let last = chapters.last else {
            return .closing(progress: duration > 0 ? min(max(screenTime / duration, 0), 1) : 1)
        }
        if screenTime < first.screen.lowerBound {
            return .opening(progress: max(0, screenTime / first.screen.lowerBound))
        }
        for (index, chapter) in chapters.enumerated() {
            if chapter.screen.contains(screenTime) { return .playing(chapter: index) }
            if index + 1 < chapters.count, screenTime < chapters[index + 1].screen.lowerBound {
                let gap = chapters[index + 1].screen.lowerBound - chapter.screen.upperBound
                return .pause(after: index, progress: gap > 0 ? (screenTime - chapter.screen.upperBound) / gap : 1)
            }
        }
        let remaining = duration - last.screen.upperBound
        return .closing(progress: remaining > 0 ? min(1, (screenTime - last.screen.upperBound) / remaining) : 1)
    }

    /// The match moment shown at `screenTime`, held within `chapter`.
    public func matchDate(at screenTime: Double, in chapter: Chapter) -> Date {
        let span = chapter.screen.upperBound - chapter.screen.lowerBound
        let share = span > 0 ? min(max((screenTime - chapter.screen.lowerBound) / span, 0), 1) : 1
        var low = 0, high = chapter.cumulative.count - 1
        while low + 1 < high {
            let middle = (low + high) / 2
            if chapter.cumulative[middle] <= share { low = middle } else { high = middle }
        }
        let gap = chapter.cumulative[high] - chapter.cumulative[low]
        let within = gap > 0 ? min(max((share - chapter.cumulative[low]) / gap, 0), 1) : 0
        let fraction = (Double(low) + within) / Double(chapter.cumulative.count - 1)
        return chapter.period.start.addingTimeInterval(fraction * chapter.period.duration)
    }

    /// When a match moment appears on screen; nil if it falls in a break.
    public func screenTime(of date: Date) -> Double? {
        guard let chapter = chapters.first(where: { $0.period.contains(date) }) else { return nil }
        let position = date.timeIntervalSince(chapter.period.start) / chapter.period.duration
            * Double(chapter.cumulative.count - 1)
        let index = min(Int(position), chapter.cumulative.count - 2)
        let share = chapter.cumulative[index]
            + (chapter.cumulative[index + 1] - chapter.cumulative[index]) * (position - Double(index))
        return chapter.screen.lowerBound + share * (chapter.screen.upperBound - chapter.screen.lowerBound)
    }

    /// Seconds of play on the clock, not counting breaks.
    public func playSeconds(at date: Date) -> Double {
        guard let chapter = chapters.last(where: { $0.period.start <= date }) else { return 0 }
        return chapter.playSecondsBefore + min(date.timeIntervalSince(chapter.period.start), chapter.period.duration)
    }
}
