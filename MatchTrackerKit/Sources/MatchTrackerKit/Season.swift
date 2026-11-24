import Foundation

// MARK: - Match digest

/// Everything a list, a season or a comparison needs to know about one match, small enough to
/// persist for every match ever played. Computed once from the full analysis; nothing that reads
/// it has to open a route.
public struct MatchDigest: Codable, Identifiable, Equatable, Sendable {
    /// Bump when a definition changes, so stale digests are recomputed rather than compared.
    public static let currentVersion = 4

    public var version: Int
    public var id: UUID
    public var startDate: Date
    public var endDate: Date
    public var format: MatchFormat
    public var fieldID: UUID?
    public var fieldName: String?
    public var opponent: String?

    /// Nil when no score was logged — not the same as 0–0.
    public var goalsUs: Int?
    public var goalsThem: Int?
    public var myGoals: Int
    public var myAssists: Int

    public var distanceMeters: Double?
    public var secondsOnPitch: TimeInterval
    public var effort: Double?
    public var topSpeedMetersPerSecond: Double?
    public var sprintCount: Int?
    public var averageHeartRate: Double?
    public var hasRoute: Bool
    /// Where the match was played, as a portrait `PortraitHeat` thumbnail. Nil without a route.
    public var heat: [Float]?
    /// Whether the top of `heat` is known to be the attacking end.
    public var heatIsDirected: Bool?

    public init(id: UUID, startDate: Date, endDate: Date, format: MatchFormat) {
        version = Self.currentVersion
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.format = format
        myGoals = 0
        myAssists = 0
        secondsOnPitch = endDate.timeIntervalSince(startDate)
        hasRoute = false
    }

    public enum Result: String, Codable, Sendable { case won, drawn, lost }

    public var result: Result? {
        guard let goalsUs, let goalsThem else { return nil }
        return goalsUs > goalsThem ? .won : goalsUs < goalsThem ? .lost : .drawn
    }

    public var distancePerHour: Double? {
        guard let distanceMeters, secondsOnPitch > 600 else { return nil }
        return distanceMeters / secondsOnPitch * 3600
    }
}

// MARK: - Personal bests

public enum PersonalBest: String, CaseIterable, Codable, Sendable {
    case topSpeed, distance, sprints, goals, longestMatch

    public func value(in digest: MatchDigest) -> Double? {
        switch self {
        case .topSpeed: return digest.topSpeedMetersPerSecond
        case .distance: return digest.distanceMeters
        case .sprints: return digest.sprintCount.map(Double.init)
        case .goals: return digest.myGoals > 0 ? Double(digest.myGoals) : nil
        // Forgotten matches run for hours; nobody's longest match is one of those.
        case .longestMatch: return digest.secondsOnPitch < 3 * 3600 ? digest.secondsOnPitch : nil
        }
    }
}

// MARK: - Season

/// A run of matches summarized: record, totals, bests and how the recent ones compare.
public struct SeasonSummary: Equatable, Sendable {
    public let matches: [MatchDigest]   // oldest first

    public init(_ digests: [MatchDigest]) {
        matches = digests.sorted { $0.startDate < $1.startDate }
    }

    public var won: Int { matches.filter { $0.result == .won }.count }
    public var drawn: Int { matches.filter { $0.result == .drawn }.count }
    public var lost: Int { matches.filter { $0.result == .lost }.count }
    public var hasResults: Bool { won + drawn + lost > 0 }

    public var distanceMeters: Double { matches.compactMap(\.distanceMeters).reduce(0, +) }
    public var secondsOnPitch: TimeInterval { matches.map(\.secondsOnPitch).reduce(0, +) }
    public var goals: Int { matches.map(\.myGoals).reduce(0, +) }
    public var assists: Int { matches.map(\.myAssists).reduce(0, +) }

    /// The match holding a best, if at least two matches compete for it.
    public func holder(of best: PersonalBest) -> (digest: MatchDigest, value: Double)? {
        let contenders = matches.compactMap { digest in best.value(in: digest).map { (digest, $0) } }
        guard contenders.count >= 2 else { return nil }
        // The earliest wins a tie: equalling a best isn't beating it.
        return contenders.reduce(contenders[0]) { $1.1 > $0.1 ? $1 : $0 }
    }

    /// Bests set by this match against everything before it.
    public func bestsSet(by id: UUID) -> [PersonalBest] {
        guard let index = matches.firstIndex(where: { $0.id == id }), index >= 2 else { return [] }
        let earlier = matches[..<index]
        return PersonalBest.allCases.filter { best in
            guard let value = best.value(in: matches[index]),
                  let previous = earlier.compactMap({ best.value(in: $0) }).max() else { return false }
            return value > previous
        }
    }

    /// Where these matches were played, together. Only the ones whose direction is known: averaged
    /// in upside down, a match would cancel another out.
    public var heat: [Float]? {
        PortraitHeat.average(matches.filter { $0.heatIsDirected == true }.compactMap(\.heat))
    }

    /// Mean effort over the `days` up to a date.
    public func averageEffort(days: Int, asOf date: Date, excluding id: UUID? = nil) -> Double? {
        let efforts = played(days: days, asOf: date).filter { $0.id != id }.compactMap(\.effort)
        return efforts.isEmpty ? nil : efforts.reduce(0, +) / Double(efforts.count)
    }

    /// The last week's load against the usual week's: effort times minutes, summed over 7 days,
    /// over the weekly mean of the last 28. Nil until there are four weeks and four matches to
    /// call usual; a ratio made of less says more about the gaps than about the player.
    public func loadRatio(asOf date: Date) -> Double? {
        guard let first = matches.first, date.timeIntervalSince(first.startDate) >= 28 * 86_400 else { return nil }
        func load(_ digests: [MatchDigest]) -> Double {
            digests.reduce(0) { $0 + ($1.effort ?? 0) * $1.secondsOnPitch / 60 }
        }
        let month = played(days: 28, asOf: date).filter { $0.effort != nil }
        guard month.count >= 4, load(month) > 0 else { return nil }
        return load(played(days: 7, asOf: date)) / (load(month) / 4)
    }

    private func played(days: Int, asOf date: Date) -> [MatchDigest] {
        matches.filter { $0.startDate <= date && date.timeIntervalSince($0.startDate) < Double(days) * 86_400 }
    }

    /// Seasons as most leagues run them: spring is January–June, fall July–December.
    public struct Term: Hashable, Comparable, Sendable {
        public let year: Int
        public let isFall: Bool

        public init(containing date: Date, calendar: Calendar = .current) {
            year = calendar.component(.year, from: date)
            isFall = calendar.component(.month, from: date) >= 7
        }

        public var title: String { "\(isFall ? "Fall" : "Spring") \(year)" }

        public static func < (lhs: Term, rhs: Term) -> Bool {
            (lhs.year, lhs.isFall ? 1 : 0) < (rhs.year, rhs.isFall ? 1 : 0)
        }
    }
}

// MARK: - The one sentence

/// Says the most interesting true thing about a match, in words a teammate would use.
/// Deterministic: the same match always reads the same.
public enum MatchHeadline {
    public static func make(for digest: MatchDigest, among history: [MatchDigest],
                            units: UnitSystem = .current) -> String? {
        let season = SeasonSummary(history.filter { $0.id != digest.id && $0.startDate < digest.startDate } + [digest])
        let bests = season.bestsSet(by: digest.id)
        if bests.contains(.topSpeed), let speed = digest.topSpeedMetersPerSecond {
            return "Your fastest yet: \(units.speed(speed).text)."
        }
        if bests.contains(.distance), let distance = digest.distanceMeters {
            return "The most ground you've covered in a match: \(units.distance(distance).text)."
        }
        if let scoring = scoring(digest) { return scoring }
        if bests.contains(.sprints), let sprints = digest.sprintCount {
            return "More sprints than any match before: \(sprints)."
        }

        // Against the same kind of match, per hour played: a 60-minute indoor game and a
        // 90-minute match, or a half on the bench, aren't otherwise comparable.
        let peers = history
            .filter { $0.id != digest.id && $0.startDate < digest.startDate && $0.format == digest.format }
            .sorted { $0.startDate > $1.startDate }
            .prefix(8)
            .compactMap(\.distancePerHour)
        guard peers.count >= 3, let pace = digest.distancePerHour else { return nil }
        let usual = peers.reduce(0, +) / Double(peers.count)
        let difference = (pace - usual) * digest.secondsOnPitch / 3600
        // As usual isn't news.
        guard abs(pace - usual) / usual >= 0.05 else { return nil }
        let amount = units.distance(abs(difference)).text
        return difference > 0 ? "You covered \(amount) more than usual." : "You covered \(amount) less than usual."
    }

    private static func scoring(_ digest: MatchDigest) -> String? {
        switch (digest.myGoals, digest.myAssists) {
        case (0, 0): return nil
        case (0, 1): return "You set up a goal."
        case (0, let assists): return "You set up \(assists) goals."
        case (3, _): return "A hat-trick."
        case (1, 0): return "You scored."
        case (2, 0): return "You scored twice."
        case (let goals, 0): return "You scored \(goals)."
        case (1, 1): return "You scored and set one up."
        case (let goals, let assists):
            return "You scored \(goals == 2 ? "twice" : "\(goals)") and set up \(assists)."
        }
    }
}
