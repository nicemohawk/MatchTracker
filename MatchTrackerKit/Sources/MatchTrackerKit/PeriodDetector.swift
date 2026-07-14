import Foundation

// MARK: - Automatic period detection

public struct PeriodDetectorConfiguration: Sendable {
    public var minimumBreak: TimeInterval        // shortest gap that reads as a period break (halftime-ish)
    public var maximumBreak: TimeInterval         // longest gap still counted as a break, not "match over"
    public var expectedPeriods: Int               // how many periods the match is expected to have

    public init() {
        self.minimumBreak = 300
        self.maximumBreak = 1500
        self.expectedPeriods = 2
    }
}

public enum PeriodDetector {
    /// How far outside the touchline (meters) counts as off-pitch for the break signal.
    private static let offPitchToleranceMeters = 5.0
    /// Below this speed (m/s) the wearer is "stationary" (matches the standing speed zone).
    private static let stationarySpeed = SpeedThresholds.walking
    /// Sub-break inactivity spans closer than this (seconds) are merged into one break.
    private static let mergeToleranceSeconds = 10.0

    /// Infers `periodEnd`/`periodStart` pairs from sustained whole-team-off signals a single
    /// device can see: long stretches where the wearer is off-pitch (when a projector is known)
    /// or stationary-at-edge, plus GPS coverage holes. Breaks whose duration falls in
    /// `minimumBreak...maximumBreak` are candidates; for a two-period match the candidate nearest
    /// the match midpoint wins. Emits `periodEnd` at each break's start and `periodStart` at its
    /// end (source `.automatic`). Returns `[]` when the track already carries period events, so it
    /// never fights manual/existing markers.
    public static func detectPeriods(track: [TrackPoint], events: [MatchEvent],
                                     projector: FieldProjector?,
                                     configuration: PeriodDetectorConfiguration) -> [MatchEvent] {
        // Never override existing period structure.
        if events.contains(where: { $0.kind == .periodStart || $0.kind == .periodEnd }) { return [] }
        // 0 = "no fixed period count" (pickup): return every qualifying break. Otherwise need >= 2
        // periods (a one-period match has no internal break to detect).
        guard configuration.expectedPeriods == 0 || configuration.expectedPeriods >= 2 else { return [] }

        let ordered = track.sorted { $0.timestamp < $1.timestamp }
        guard ordered.count >= 2,
              let matchStart = ordered.first?.timestamp,
              let matchEnd = ordered.last?.timestamp,
              matchEnd > matchStart else { return [] }

        let speeds = rawPointSpeeds(ordered)

        // Raw break spans: runs of inactive fixes, plus inter-fix coverage holes.
        var spans: [DateInterval] = []

        var runStart: Date?
        var runEnd: Date?
        for index in ordered.indices {
            if isInactive(point: ordered[index], speed: speeds[index], projector: projector) {
                if runStart == nil { runStart = ordered[index].timestamp }
                runEnd = ordered[index].timestamp
            } else if let start = runStart, let end = runEnd, end > start {
                spans.append(DateInterval(start: start, end: end))
                runStart = nil; runEnd = nil
            } else {
                runStart = nil; runEnd = nil
            }

            // Coverage hole: a large jump to the next fix is itself a candidate break span.
            if index < ordered.count - 1 {
                let gap = ordered[index + 1].timestamp.timeIntervalSince(ordered[index].timestamp)
                if gap > mergeToleranceSeconds {
                    spans.append(DateInterval(start: ordered[index].timestamp, end: ordered[index + 1].timestamp))
                }
            }
        }
        if let start = runStart, let end = runEnd, end > start {
            spans.append(DateInterval(start: start, end: end))
        }

        let breaks = candidateBreaks(from: spans, configuration: configuration)
        guard !breaks.isEmpty else { return [] }

        let chosen = selectBreaks(breaks, matchStart: matchStart, matchEnd: matchEnd, configuration: configuration)

        var result: [MatchEvent] = []
        for interval in chosen {
            result.append(MatchEvent(kind: .periodEnd, date: interval.start, source: .automatic))
            result.append(MatchEvent(kind: .periodStart, date: interval.end, source: .automatic))
        }
        return result.sorted { $0.date < $1.date }
    }

    /// Whether a fix reads as a break: off-pitch (needs a projector), or stationary — anywhere
    /// when no field is known, otherwise only near a field edge (players idle at the touchline
    /// during breaks, not mid-pitch).
    private static func isInactive(point: TrackPoint, speed: Double, projector: FieldProjector?) -> Bool {
        guard let projector else { return speed < stationarySpeed }
        if !projector.contains(point.coordinate, toleranceMeters: offPitchToleranceMeters) { return true }
        guard speed < stationarySpeed, let normalized = projector.normalizedPoint(for: point.coordinate) else { return false }
        return normalized.x < 0.15 || normalized.x > 0.85 || normalized.y < 0.15 || normalized.y > 0.85
    }

    /// Merge overlapping/adjacent break spans, then keep those whose duration is in range.
    private static func candidateBreaks(from spans: [DateInterval], configuration: PeriodDetectorConfiguration) -> [DateInterval] {
        guard !spans.isEmpty else { return [] }
        let sorted = spans.sorted { $0.start < $1.start }

        var merged: [DateInterval] = [sorted[0]]
        for span in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            if span.start <= last.end.addingTimeInterval(mergeToleranceSeconds) {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, span.end))
            } else {
                merged.append(span)
            }
        }

        return merged.filter { $0.duration >= configuration.minimumBreak && $0.duration <= configuration.maximumBreak }
    }

    /// Pick which candidate breaks become period boundaries. For a pickup session
    /// (`expectedPeriods == 0`) every qualifying break is a boundary. For two periods, take the
    /// single break nearest the match midpoint; otherwise take the `expectedPeriods - 1` longest.
    private static func selectBreaks(_ breaks: [DateInterval], matchStart: Date, matchEnd: Date,
                                     configuration: PeriodDetectorConfiguration) -> [DateInterval] {
        if configuration.expectedPeriods == 0 {
            return breaks.sorted { $0.start < $1.start }
        }

        let wanted = configuration.expectedPeriods - 1
        guard wanted >= 1 else { return [] }

        if configuration.expectedPeriods == 2 {
            let midpoint = matchStart.addingTimeInterval(matchEnd.timeIntervalSince(matchStart) / 2)
            let nearest = breaks.min { lhs, rhs in
                abs(center(of: lhs).timeIntervalSince(midpoint)) < abs(center(of: rhs).timeIntervalSince(midpoint))
            }
            return nearest.map { [$0] } ?? []
        }

        return breaks
            .sorted { $0.duration > $1.duration }
            .prefix(wanted)
            .sorted { $0.start < $1.start }
    }

    private static func center(of interval: DateInterval) -> Date {
        interval.start.addingTimeInterval(interval.duration / 2)
    }
}
