import Foundation

/// The minutes football counts: the first is 1, and the clock stops for half-time.
public struct MatchMinutes: Equatable, Sendable {
    public let kickoff: Date
    /// Nil when nobody knows, and then nothing is left out.
    public let halftime: DateInterval?

    public init(kickoff: Date, halftime: DateInterval?) {
        self.kickoff = kickoff
        self.halftime = halftime
    }

    /// Seconds since kickoff, less any half-time among them.
    public func playedSeconds(at date: Date) -> TimeInterval {
        let elapsed = date.timeIntervalSince(kickoff)
        guard let halftime else { return elapsed }
        return elapsed - max(0, min(date, halftime.end).timeIntervalSince(max(kickoff, halftime.start)))
    }

    public func minute(of date: Date) -> Int { max(1, Int(playedSeconds(at: date) / 60) + 1) }

    public func isHalftime(_ date: Date) -> Bool {
        halftime.map { $0.start <= date && date < $0.end } ?? false
    }

    /// "23′", or "HT".
    public func text(for date: Date) -> String { isHalftime(date) ? "HT" : "\(minute(of: date))′" }

    /// "Minute 23", or "Half-time".
    public func spoken(for date: Date) -> String { isHalftime(date) ? "Half-time" : "Minute \(minute(of: date))" }

    /// The middle of a minute, in play.
    public func date(ofMinute minute: Int) -> Date {
        let date = kickoff.addingTimeInterval(Double(minute - 1) * 60 + 30)
        guard let halftime, halftime.end > kickoff, date >= halftime.start else { return date }
        return date.addingTimeInterval(halftime.end.timeIntervalSince(max(kickoff, halftime.start)))
    }
}
