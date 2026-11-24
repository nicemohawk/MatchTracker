import Foundation

/// What the iPhone's widgets, Siri answers and Spotlight know: a small file the app writes to the
/// app group, so none of them needs HealthKit or a route.
public struct WidgetSnapshot: Codable, Sendable {
    public struct Season: Codable, Equatable, Sendable {
        public var title: String
        public var matchCount: Int
        public var won: Int
        public var drawn: Int
        public var lost: Int
        public var goals: Int
        public var assists: Int
        public var distanceMeters: Double
        public var secondsOnPitch: TimeInterval
        /// The last five results, oldest first.
        public var form: [MatchDigest.Result]

        public var hasResults: Bool { won + drawn + lost > 0 }
    }

    /// The region's convention, or the override chosen in the app, which an extension can't see.
    public var units: UnitSystem
    public var lastMatch: MatchDigest?
    /// The one sentence about the last match.
    public var headline: String?
    /// Where the last match was played on the pitch, coarse enough for a thumbnail.
    public var heat: HeatmapGrid?
    public var season: Season?
    /// Newest first: what Siri and Spotlight can open.
    public var recent: [MatchDigest]

    public static let recentLimit = 100
    static let heatColumns = 30, heatRows = 20

    public static func make(from digests: [MatchDigest], heat: HeatmapGrid? = nil,
                            units: UnitSystem = .current, now: Date = Date(),
                            calendar: Calendar = .current) -> WidgetSnapshot {
        let newestFirst = digests.sorted { $0.startDate > $1.startDate }.map { digest in
            // Nothing on these surfaces shows it, so it doesn't leave the app.
            var digest = digest
            digest.averageHeartRate = nil
            return digest
        }
        return WidgetSnapshot(
            units: units,
            lastMatch: newestFirst.first,
            headline: newestFirst.first.flatMap { MatchHeadline.make(for: $0, among: newestFirst, units: units) },
            heat: newestFirst.isEmpty ? nil : heat?.reduced(columns: heatColumns, rows: heatRows),
            season: season(from: newestFirst, now: now, calendar: calendar),
            recent: Array(newestFirst.prefix(recentLimit)))
    }

    /// This season, or between seasons the last one played.
    private static func season(from digests: [MatchDigest], now: Date, calendar: Calendar) -> Season? {
        func term(_ date: Date) -> SeasonSummary.Term { SeasonSummary.Term(containing: date, calendar: calendar) }
        guard let latest = digests.map({ term($0.startDate) }).max() else { return nil }
        let current = term(now)
        let shown = digests.contains { term($0.startDate) == current } ? current : latest
        let summary = SeasonSummary(digests.filter { term($0.startDate) == shown })
        return Season(title: shown.title, matchCount: summary.matches.count,
                      won: summary.won, drawn: summary.drawn, lost: summary.lost,
                      goals: summary.goals, assists: summary.assists,
                      distanceMeters: summary.distanceMeters, secondsOnPitch: summary.secondsOnPitch,
                      form: Array(summary.matches.compactMap(\.result).suffix(5)))
    }

    // MARK: Storage

    public static func fileURL(in containerURL: URL) -> URL {
        containerURL.appendingPathComponent("widget-snapshot.json")
    }

    public static func load(from containerURL: URL) -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL(in: containerURL)) else { return nil }
        return try? MatchTrackerJSON.decoder().decode(WidgetSnapshot.self, from: data)
    }

    /// Returns whether anything changed, so widgets are only reloaded when there's something new.
    @discardableResult
    public func save(to containerURL: URL) throws -> Bool {
        let encoder = MatchTrackerJSON.encoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(self)
        let url = Self.fileURL(in: containerURL)
        guard data != (try? Data(contentsOf: url)) else { return false }
        try data.write(to: url, options: .atomic)
        return true
    }
}

// MARK: - Words

extension WidgetSnapshot {
    /// What Siri says about the last match.
    public var spokenLastMatch: String {
        guard let match = lastMatch else { return "You haven't recorded a match yet." }
        var sentences = [match.spokenSummary]
        let minutes = Int((match.secondsOnPitch / 60).rounded())
        if let distance = match.distanceMeters, distance > 0 {
            sentences.append("You covered \(units.roughDistance(distance).spoken) in \(minutes) minutes.")
        } else {
            sentences.append("You were on the pitch for \(minutes) minutes.")
        }
        if let headline { sentences.append(headline) }
        return sentences.joined(separator: " ")
    }

    /// What Siri says about the season.
    public var spokenSeason: String {
        guard let season else { return "You haven't recorded a match yet." }
        let played = season.matchCount == 1 ? "1 match" : "\(season.matchCount) matches"
        var sentences: [String] = []
        if season.hasResults {
            sentences.append("\(season.title): \(season.won) won, \(season.drawn) drawn, \(season.lost) lost.")
            // A match nobody kept score in is played, but it isn't in the record.
            if season.won + season.drawn + season.lost < season.matchCount {
                sentences.append("\(played) in all.")
            }
        } else {
            sentences.append("\(season.title): \(played).")
        }
        if season.distanceMeters > 0 {
            sentences.append("You've covered \(units.totalDistance(season.distanceMeters).spoken).")
        }
        if season.goals > 0 {
            sentences.append(season.goals == 1 ? "You've scored once." : "You've scored \(season.goals) goals.")
        }
        return sentences.joined(separator: " ")
    }
}

extension MatchDigest.Result {
    public var title: String {
        switch self {
        case .won: return "Won"
        case .drawn: return "Drew"
        case .lost: return "Lost"
        }
    }

    public var letter: String {
        switch self {
        case .won: return "W"
        case .drawn: return "D"
        case .lost: return "L"
        }
    }
}

extension MatchDigest {
    public var score: String? {
        guard let goalsUs, let goalsThem else { return nil }
        return "\(goalsUs)–\(goalsThem)"
    }

    /// What to call the match when there's only room for one line: who, else where, else what.
    public var title: String {
        if let opponent { return "vs \(opponent)" }
        if let fieldName { return fieldName }
        switch format {
        case .match: return "Match"
        case .smallSided: return "Pickup"
        case .indoor: return "Indoor"
        }
    }

    /// "You won 3 to 1 against Rovers on Saturday, October 3."
    public var spokenSummary: String {
        let versus = opponent.map { " against \($0)" } ?? ""
        let day = startDate.formatted(.dateTime.weekday(.wide).month(.wide).day())
        guard let goalsUs, let goalsThem, let result else { return "You played\(versus) on \(day)." }
        switch result {
        case .won: return "You won \(goalsUs) to \(goalsThem)\(versus) on \(day)."
        case .lost: return "You lost \(goalsThem) to \(goalsUs)\(versus) on \(day)."
        case .drawn: return "You drew \(goalsUs) all\(versus) on \(day)."
        }
    }
}

extension HeatmapGrid {
    /// A grid no finer than this, normalized again and rounded so it stays a few kilobytes of JSON.
    func reduced(columns targetColumns: Int, rows targetRows: Int) -> HeatmapGrid {
        guard columns > 0, rows > 0 else { return self }
        let newColumns = min(columns, targetColumns), newRows = min(rows, targetRows)
        var sums = [Double](repeating: 0, count: newColumns * newRows)
        for row in 0..<rows {
            for column in 0..<columns {
                sums[(row * newRows / rows) * newColumns + column * newColumns / columns] += self[column, row]
            }
        }
        let peak = sums.max() ?? 0
        let cells = peak > 0 ? sums.map { ($0 / peak * 100).rounded() / 100 } : sums
        return HeatmapGrid(columns: newColumns, rows: newRows, cells: cells)
    }
}
