import Foundation

/// A match in progress, reduced from the watch's stream to what a glance needs. Small enough for a
/// Live Activity, and it never claims more than the last update said.
public struct LiveMatchState: Codable, Hashable, Sendable {
    public var startDate: Date
    /// When the watch said all this.
    public var updatedAt: Date
    /// Played time as of `updatedAt`, pauses excluded.
    public var elapsed: TimeInterval
    public var isPaused = false
    public var isAtBreak = false
    public var hasEnded = false
    /// Nil until the watch has said.
    public var onPitch: Bool?
    /// Both nil until a goal is logged — not the same as 0–0.
    public var goalsUs: Int?
    public var goalsThem: Int?
    public var distanceMeters: Double
    public var heartRate: Int?

    public init(_ update: LiveMatchUpdate) {
        startDate = update.newEvents.first { $0.kind == .matchStart }?.date
            ?? update.timestamp.addingTimeInterval(-update.elapsed)
        updatedAt = update.timestamp
        elapsed = update.elapsed
        distanceMeters = update.distanceMeters
        read(update)
    }

    /// A match known to be under way before the first update arrives.
    public init(startDate: Date, now: Date = Date()) {
        self.startDate = startDate
        updatedAt = now
        elapsed = max(0, now.timeIntervalSince(startDate))
        distanceMeters = 0
    }

    public mutating func apply(_ update: LiveMatchUpdate) {
        // The stream doesn't say it's paused; a clock that stopped moving does.
        let wallClock = update.timestamp.timeIntervalSince(updatedAt)
        if wallClock >= 2 {
            isPaused = update.elapsed - elapsed < wallClock / 2
        }
        updatedAt = update.timestamp
        elapsed = update.elapsed
        distanceMeters = update.distanceMeters
        read(update)
    }

    private mutating func read(_ update: LiveMatchUpdate) {
        onPitch = update.onPitch
        // Always the current totals; nil again when the only goal was undone.
        goalsUs = update.usGoals
        goalsThem = update.themGoals
        heartRate = update.heartRate.map { Int($0.rounded()) }
        for event in update.newEvents {
            switch event.kind {
            case .periodEnd: isAtBreak = true
            case .periodStart: isAtBreak = false
            case .matchEnd: hasEnded = true
            default: break
            }
        }
    }

    /// Where a running clock counts up from.
    public var clockStart: Date { updatedAt.addingTimeInterval(-elapsed) }

    public var isClockRunning: Bool { !isPaused && !hasEnded }

    public var score: String? {
        guard let goalsUs, let goalsThem else { return nil }
        return "\(goalsUs)–\(goalsThem)"
    }

    /// Worth redrawing right away, unlike the numbers that drift every few seconds.
    public func isNews(since other: LiveMatchState) -> Bool {
        goalsUs != other.goalsUs || goalsThem != other.goalsThem || onPitch != other.onPitch
            || isPaused != other.isPaused || isAtBreak != other.isAtBreak || hasEnded != other.hasEnded
    }
}

// MARK: - Words

extension LiveMatchState {
    public var status: String {
        if hasEnded { return "Full time" }
        if isAtBreak { return "Half-time" }
        if isPaused { return "Paused" }
        switch onPitch {
        case true?: return "On the pitch"
        case false?: return "On the bench"
        case nil: return "Under way"
        }
    }

    /// "Won 3–1", when somebody kept score.
    public var finalTitle: String {
        MatchResultText.title(goalsUs: goalsUs, goalsThem: goalsThem) ?? "Match finished"
    }

    public func finalDetail(units: UnitSystem) -> String {
        let minutes = UnitSystem.minutes(elapsed).text
        guard distanceMeters > 0 else { return minutes }
        return "\(units.roughDistance(distanceMeters).text) · \(minutes)"
    }

    public var spokenScore: String {
        guard let goalsUs, let goalsThem else { return "No goals logged" }
        if goalsUs == goalsThem { return "Level at \(goalsUs) all" }
        return goalsUs > goalsThem ? "You lead \(goalsUs) to \(goalsThem)" : "You trail \(goalsThem) to \(goalsUs)"
    }
}

/// A result in the words a teammate would use.
public enum MatchResultText {
    public static func title(goalsUs: Int?, goalsThem: Int?) -> String? {
        guard let goalsUs, let goalsThem else { return nil }
        let verb = goalsUs > goalsThem ? "Won" : goalsUs < goalsThem ? "Lost" : "Drew"
        return "\(verb) \(goalsUs)–\(goalsThem)"
    }
}

extension UnitSystem {
    /// One decimal: plenty for a glance.
    public func roughDistance(_ meters: Double, locale: Locale = .current) -> Measure {
        rounded(meters, fractionDigits: 1, locale: locale)
    }

    /// A season's total, where decimals stop meaning anything past a hundred.
    public func totalDistance(_ meters: Double, locale: Locale = .current) -> Measure {
        rounded(meters, fractionDigits: longDistanceValue(meters) >= 100 ? 0 : 1, locale: locale)
    }

    public static func minutes(_ seconds: TimeInterval) -> Measure {
        let minutes = Int((seconds / 60).rounded())
        return Measure(value: "\(minutes)", unit: "min", spokenUnit: minutes == 1 ? "minute" : "minutes")
    }

    private func longDistanceValue(_ meters: Double) -> Double {
        self == .metric ? meters / 1000 : meters / 1609.344
    }

    private func rounded(_ meters: Double, fractionDigits: Int, locale: Locale) -> Measure {
        let exact = distance(meters, locale: locale)
        return Measure(value: longDistanceValue(meters)
                        .formatted(.number.precision(.fractionLength(fractionDigits)).locale(locale)),
                       unit: exact.unit, spokenUnit: exact.spokenUnit)
    }
}
