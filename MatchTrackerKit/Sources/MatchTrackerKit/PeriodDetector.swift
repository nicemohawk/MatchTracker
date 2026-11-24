import Foundation

// MARK: - Automatic period detection

public struct PeriodDetectorConfiguration: Sendable {
    public var minimumBreak: TimeInterval        // shortest gap that reads as a period break (halftime-ish)
    public var maximumBreak: TimeInterval         // longest gap still counted as a break, not "match over"
    public var expectedPeriods: Int               // how many periods the match is expected to have
    /// Where halftime may fall, as a fraction of the playing time before and after it.
    public var halftimeFraction: ClosedRange<Double>

    public init() {
        self.minimumBreak = 180
        self.maximumBreak = 1500
        self.expectedPeriods = 2
        self.halftimeFraction = 0.35...0.65
    }
}

public enum PeriodDetector {
    private static let binSeconds = 10.0
    /// Activity is averaged over this many bins either side, so one jog to fetch a ball doesn't
    /// end halftime and one stoppage doesn't start it.
    private static let smoothingBins = 3
    /// A minute is quiet below this fraction of the match's usual activity.
    private static let quietFraction = 0.4
    /// Halftime isn't all standing still: quiet stretches with this little (seconds) between them
    /// are one break, so long as what's between is gentler than play.
    private static let bridgedSeconds = 120.0
    private static let bridgedFraction = 0.8
    /// Minutes below this speed (m/s) say nothing about how active the match usually was.
    private static let activeSpeed = SpeedThresholds.walking

    /// Infers `periodEnd`/`periodStart` pairs from the stretches where the wearer all but stops
    /// moving, or where there are no fixes at all. A field isn't needed, so a wrong one can't
    /// mislead it.
    ///
    /// Standing about before kickoff and after the final whistle is not playing time. For a
    /// two-period match the break must split the playing time near the middle
    /// (`halftimeFraction`); the one nearest half wins, and none is better than a wrong one.
    /// Emits `periodEnd` at each break's start and `periodStart` at its end (source `.automatic`).
    /// Returns `[]` when period events already exist, so it never fights manual markers.
    public static func detectPeriods(track: [TrackPoint], events: [MatchEvent],
                                     configuration: PeriodDetectorConfiguration = .init()) -> [MatchEvent] {
        // Never override existing period structure.
        if events.contains(where: { $0.kind == .periodStart || $0.kind == .periodEnd }) { return [] }
        // 0 = "no fixed period count" (pickup): return every qualifying break. Otherwise need >= 2
        // periods (a one-period match has no internal break to detect).
        guard configuration.expectedPeriods == 0 || configuration.expectedPeriods >= 2 else { return [] }

        return breaks(in: track, configuration: configuration).flatMap {
            [MatchEvent(kind: .periodEnd, date: $0.start, source: .automatic),
             MatchEvent(kind: .periodStart, date: $0.end, source: .automatic)]
        }
    }

    /// Halftime of a formal match: what the wearer marked, if believable, else what the track shows.
    /// Automatic events already on the record are ignored; the track is the better witness.
    public static func halftime(track: [TrackPoint], events: [MatchEvent], interval: DateInterval) -> DateInterval? {
        let manual = events
            .filter { $0.source == .manual && interval.contains($0.date) }
            .sorted { $0.date < $1.date }
        let marked = manual.filter { $0.kind == .periodEnd }.compactMap { end in
            manual.first { $0.kind == .periodStart && $0.date > end.date }
                .map { DateInterval(start: end.date, end: $0.date) }
        }
        let believable = marked.first {
            let fraction = $0.start.timeIntervalSince(interval.start) / max(interval.duration - $0.duration, 1)
            return $0.duration <= 45 * 60 && (0.2...0.8).contains(fraction)
        }
        return believable ?? breaks(in: track, configuration: .init()).first
    }

    private static func breaks(in track: [TrackPoint], configuration: PeriodDetectorConfiguration) -> [DateInterval] {
        let ordered = track.sorted { $0.timestamp < $1.timestamp }
        guard let start = ordered.first?.timestamp, let end = ordered.last?.timestamp, end > start else { return [] }

        let activity = smoothedActivity(of: ordered, from: start, to: end)
        let active = activity.filter { $0 >= activeSpeed }
        guard !active.isEmpty else { return [] }
        let usual = median(active)
        let quiet = activity.map { $0 < quietFraction * usual }

        guard let firstPlayed = quiet.firstIndex(of: false), let lastPlayed = quiet.lastIndex(of: false) else { return [] }

        // Runs of quiet bins strictly inside play.
        var candidates: [Range<Int>] = []
        var runStart: Int?
        for index in firstPlayed...lastPlayed {
            if quiet[index] {
                runStart = runStart ?? index
            } else if let first = runStart {
                candidates.append(first..<index)
                runStart = nil
            }
        }
        candidates = candidates.reduce(into: []) { merged, next in
            if let last = merged.last,
               Double(next.lowerBound - last.upperBound) * binSeconds <= bridgedSeconds,
               mean(Array(activity[last.upperBound..<next.lowerBound])) < bridgedFraction * usual {
                merged[merged.count - 1] = last.lowerBound..<next.upperBound
            } else {
                merged.append(next)
            }
        }
        let qualifying = candidates.filter {
            let duration = Double($0.count) * binSeconds
            return duration >= configuration.minimumBreak && duration <= configuration.maximumBreak
        }

        func interval(_ bins: Range<Int>) -> DateInterval {
            DateInterval(start: start.addingTimeInterval(Double(bins.lowerBound) * binSeconds),
                         end: start.addingTimeInterval(Double(bins.upperBound) * binSeconds))
        }
        func playedFraction(_ bins: Range<Int>) -> Double {
            let before = Double(bins.lowerBound - firstPlayed), after = Double(lastPlayed + 1 - bins.upperBound)
            return before / (before + after)
        }

        switch configuration.expectedPeriods {
        case 0:
            return qualifying.map(interval)
        case 2:
            return qualifying
                .filter { configuration.halftimeFraction.contains(playedFraction($0)) }
                .min { abs(playedFraction($0) - 0.5) < abs(playedFraction($1) - 0.5) }
                .map { [interval($0)] } ?? []
        default:
            return qualifying
                .sorted { $0.count > $1.count }
                .prefix(configuration.expectedPeriods - 1)
                .map(interval)
                .sorted { $0.start < $1.start }
        }
    }

    /// Mean speed per bin, smoothed. A bin without fixes is as quiet as one standing still.
    private static func smoothedActivity(of track: [TrackPoint], from start: Date, to end: Date) -> [Double] {
        let count = Int(end.timeIntervalSince(start) / binSeconds) + 1
        var sums = [Double](repeating: 0, count: count)
        var samples = [Double](repeating: 0, count: count)
        for (point, speed) in zip(track, rawPointSpeeds(track)) {
            let bin = Int(point.timestamp.timeIntervalSince(start) / binSeconds)
            sums[bin] += min(speed, SpeedThresholds.plausibleMaximum)
            samples[bin] += 1
        }
        let activity = zip(sums, samples).map { $1 > 0 ? $0 / $1 : 0 }
        return activity.indices.map { index in
            mean(Array(activity[max(0, index - smoothingBins)...min(count - 1, index + smoothingBins)]))
        }
    }
}
