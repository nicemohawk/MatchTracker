import Foundation

/// One short game of several played in a booking.
public struct GameResult: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var start: Date
    public var end: Date
    /// Nil until somebody has said, which isn't 0–0.
    public var score: FinalScore?
    /// How it went, for when that's all anyone remembers.
    public var outcome: MatchDigest.Result?

    public init(id: UUID = UUID(), start: Date, end: Date, score: FinalScore? = nil, outcome: MatchDigest.Result? = nil) {
        self.outcome = outcome
        self.id = id
        self.start = start
        self.end = end
        self.score = score
    }
}

public enum Games {
    /// The games in a session that held several, best known first: what the wearer has said, then
    /// where they marked one ending, then as many as fit in each block of playing. Whether it did
    /// hold several is for them to say: two blocks may as well be two halves.
    /// - Parameter length: How long a game usually is here. Nil makes each block one game.
    public static func inSession(record: MatchRecord?, stints: Stints?, interval: DateInterval,
                                 length: TimeInterval?) -> [GameResult] {
        if let games = record?.games { return games }
        let events = record?.events ?? []
        let endings = events.filter { $0.kind == .periodEnd && $0.source == .manual && interval.contains($0.date) }
            .map(\.date).sorted()
        let spans: [DateInterval]
        if !endings.isEmpty {
            spans = marked(endings, playing: stints?.playing ?? [], interval: interval)
        } else if let stints {
            spans = stints.games.flatMap { split(block: $0, length: length) }
        } else {
            return []
        }
        guard spans.count > 1 else { return [] }
        return spans.map { span in
            GameResult(start: span.start, end: span.end, score: logged(events, in: span))
        }
    }

    /// Goals are tapped after they're scored, and the last one as the whistle goes.
    private static let afterwards: TimeInterval = 45

    private static func logged(_ events: [MatchEvent], in span: DateInterval) -> FinalScore? {
        let goals = events.filter { $0.date >= span.start && $0.date < span.end.addingTimeInterval(afterwards) }
        var record = MatchRecord(id: UUID(), startDate: span.start, endDate: span.end, fieldID: nil, events: goals, teamCode: nil)
        record.finalScore = nil
        return record.loggedScore
    }

    private static func marked(_ endings: [Date], playing: [DateInterval], interval: DateInterval) -> [DateInterval] {
        var start = interval.start
        var spans = endings.map { ending -> DateInterval in
            defer { start = ending }
            return DateInterval(start: start, end: max(ending, start))
        }
        // Whatever was played after the last one marked was another, unless it was only packing up.
        let after = DateInterval(start: start, end: max(interval.end, start))
        let played = playing.isEmpty ? after.duration : playing.compactMap { $0.intersection(with: after)?.duration }.reduce(0, +)
        if played >= 4 * 60 { spans.append(after) }
        // Sitting out before a game isn't part of it.
        return spans.map { span in
            let first = playing.first { $0.end > span.start && $0.start < span.end }
            return DateInterval(start: max(span.start, first?.start ?? span.start), end: span.end)
        }
    }

    /// A block as however many games fit, parted at the rests nearest to where games would end.
    private static func split(block: [DateInterval], length: TimeInterval?) -> [DateInterval] {
        guard let first = block.first, let last = block.last else { return [] }
        let whole = DateInterval(start: first.start, end: last.end)
        guard let length, length > 0 else { return [whole] }
        let count = max(1, Int((whole.duration / length).rounded()))
        guard count > 1 else { return [whole] }
        let rests = zip(block, block.dropFirst()).map { DateInterval(start: $0.end, end: max($1.start, $0.end)) }
        var spans: [DateInterval] = [], start = whole.start
        for game in 1..<count {
            let expected = whole.start.addingTimeInterval(whole.duration * Double(game) / Double(count))
            let rest = rests.filter { $0.start > start }
                .min { abs($0.start.timeIntervalSince(expected)) < abs($1.start.timeIntervalSince(expected)) }
                .flatMap { abs($0.start.timeIntervalSince(expected)) < length * 0.35 ? $0 : nil }
            spans.append(DateInterval(start: start, end: rest?.start ?? expected))
            start = rest?.end ?? expected
        }
        spans.append(DateInterval(start: start, end: max(whole.end, start)))
        return spans
    }

    /// How many were won, drawn and lost. Nil when none has a score.
    public static func tally(_ games: [GameResult]) -> GameTally? {
        let outcomes = games.compactMap { $0.outcome ?? $0.score?.outcome }
        guard !outcomes.isEmpty else { return nil }
        return GameTally(won: outcomes.filter { $0 == .won }.count, drawn: outcomes.filter { $0 == .drawn }.count,
                         lost: outcomes.filter { $0 == .lost }.count)
    }
}

public extension FinalScore {
    var outcome: MatchDigest.Result { us > them ? .won : us < them ? .lost : .drawn }
}

/// How somebody plays, as far as they've said, for each kind of match: the next one starts from it.
public struct PlayHabits: Codable, Equatable, Sendable {
    public struct Habit: Codable, Equatable, Sendable {
        public var keepsScore: Bool?
        public var playsSeveralGames: Bool?
        /// How long a game lasts, from the sessions whose games were counted.
        public var gameSeconds: TimeInterval?

        public init() {}
    }

    private var habits: [String: Habit] = [:]

    public init() {}

    public subscript(format: MatchFormat) -> Habit {
        get { habits[format.rawValue] ?? Habit() }
        set { habits[format.rawValue] = newValue }
    }

    /// Learn from a session somebody has just described.
    public mutating func learn(format: MatchFormat, keepsScore: Bool, games: Int?, played: TimeInterval) {
        var habit = self[format]
        habit.keepsScore = keepsScore
        if let games {
            habit.playsSeveralGames = games > 1
            if games > 1, played > 0 { habit.gameSeconds = played / Double(games) }
        }
        self[format] = habit
    }
}

public struct GameTally: Codable, Sendable, Equatable {
    public var won: Int
    public var drawn: Int
    public var lost: Int

    public init(won: Int, drawn: Int, lost: Int) {
        self.won = won
        self.drawn = drawn
        self.lost = lost
    }

    public var count: Int { won + drawn + lost }
    /// "Won 3 of 5".
    public var title: String { "Won \(won) of \(count)" }
}
