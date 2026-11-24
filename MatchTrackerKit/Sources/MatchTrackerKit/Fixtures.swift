import Foundation

// MARK: - Fixtures from the calendar

/// The parts of a calendar event that matter for spotting a match. Keeps EventKit out of the Kit.
public struct CalendarEvent: Equatable, Sendable {
    public var id: String
    public var title: String
    public var location: String?
    public var coordinate: Coordinate2D?
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var isCanceled: Bool

    public init(id: String, title: String, location: String? = nil, coordinate: Coordinate2D? = nil,
                start: Date, end: Date, isAllDay: Bool = false, isCanceled: Bool = false) {
        self.id = id
        self.title = title
        self.location = location
        self.coordinate = coordinate
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.isCanceled = isCanceled
    }
}

/// A match found in the calendar. `opponent` is a reading of someone else's event title, so it is
/// always offered, never assumed.
public struct Fixture: Identifiable, Equatable, Sendable {
    public enum Venue: Equatable, Sendable { case home, away }

    public var id: String
    public var title: String
    public var opponent: String?
    public var venue: Venue?
    public var location: String?
    public var coordinate: Coordinate2D?
    public var start: Date
    public var end: Date

    public init(id: String, title: String, opponent: String? = nil, venue: Venue? = nil,
                location: String? = nil, coordinate: Coordinate2D? = nil, start: Date, end: Date) {
        self.id = id
        self.title = title
        self.opponent = opponent
        self.venue = venue
        self.location = location
        self.coordinate = coordinate
        self.start = start
        self.end = end
    }
}

public enum FixtureParser {
    /// Matches among calendar events, soonest first. `teamNames` are the player's own teams; a name
    /// that keeps turning up in the calendar's own titles counts as one of them too.
    public static func fixtures(in events: [CalendarEvent], teamNames: [String] = []) -> [Fixture] {
        let ownNames = teamNames.filter { !$0.isEmpty } + recurringTeamName(in: events.map(\.title))
        return events
            .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
            .compactMap { fixture(from: $0, teamNames: ownNames) }
    }

    public static func fixture(from event: CalendarEvent, teamNames: [String]) -> Fixture? {
        let duration = event.end.timeIntervalSince(event.start)
        guard !event.isAllDay, !event.isCanceled, duration >= 0, duration <= 6 * 3600 else { return nil }
        let title = cleaned(event.title)
        guard !title.isEmpty, !containsWord(title, canceledWords) else { return nil }
        let saysMatch = containsWord(title, matchWords)
        guard saysMatch || !containsWord(title, trainingWords), !containsWord(title, otherActivityWords) else { return nil }
        guard let reading = read(title, teamNames: teamNames, saysMatch: saysMatch) else { return nil }
        return Fixture(id: event.id, title: title, opponent: reading.opponent, venue: reading.venue,
                       location: firstLine(event.location), coordinate: event.coordinate, start: event.start,
                       // Some feeds leave the end equal to the start.
                       end: duration < 60 ? event.start.addingTimeInterval(2 * 3600) : event.end)
    }

    // MARK: Reading a title

    private typealias Reading = (opponent: String?, venue: Fixture.Venue?)

    private static func read(_ title: String, teamNames: [String], saysMatch: Bool) -> Reading? {
        if let (left, right) = split(title, by: versusPattern) {
            if isOwn(right, teamNames), !isOwn(left, teamNames) {
                return (opponentName(left, teamNames: teamNames), venueMark(in: title) ?? .away)
            }
            return (opponentName(right, teamNames: teamNames), venueMark(in: title))
        }
        // "Us at Them" names an opponent; "Match at Riverside Park" names a place.
        if let (left, right) = split(title, by: atPattern) {
            if isOwn(left, teamNames) { return (opponentName(right, teamNames: teamNames), .away) }
            if isOwn(right, teamNames) { return (opponentName(left, teamNames: teamNames), .home) }
        }
        guard saysMatch else { return nil }
        // "Match: Rovers (A)", "Friendly - Rovers"
        guard let label = title.range(of: labelPattern, options: [.regularExpression, .caseInsensitive]) else {
            return (nil, venueMark(in: title))
        }
        return (opponentName(String(title[label.upperBound...]), teamNames: teamNames), venueMark(in: title))
    }

    /// The team name that appears in at least two titles and in more than any other does.
    private static func recurringTeamName(in titles: [String]) -> [String] {
        var counts: [String: (name: String, count: Int)] = [:]
        for title in titles.map(cleaned) {
            guard let (left, right) = split(title, by: versusPattern) ?? split(title, by: atPattern) else { continue }
            for name in [left, right].map(strippedOfMatchLabel) {
                let key = normalized(name)
                guard !genericSides.contains(key) else { continue }
                counts[key, default: (name, 0)].count += 1
            }
        }
        let ranked = counts.values.sorted { $0.count > $1.count }
        guard let first = ranked.first, first.count >= 2, ranked.count < 2 || ranked[1].count < first.count else { return [] }
        return [first.name]
    }

    private static func opponentName(_ side: String, teamNames: [String]) -> String? {
        let afterTheName = [
            #"\s+(@|at)\s+.*$"#,                          // a place
            #"\s*[|•·,;]\s*.*$"#,                         // a second clause
            #"\s*[\(\[][^\)\]]*[\)\]]\s*"#,               // (Home), [U14]
            #"\s+[-–—]\s+.*$"#,
            #"\s+(on\s+)?(field|pitch|court)\s*\S*$"#,
            #"\s+\d+\s*[-–:]\s*\d+$"#,                    // a score
            #"\s+(home|away)$"#
        ]
        var name = side
        for pattern in afterTheName {
            name = name.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        name = strippedOfMatchLabel(name)
        let key = normalized(name)
        guard key.contains(where: \.isLetter), !genericSides.contains(key), !isOwn(name, teamNames) else { return nil }
        return name
    }

    /// "Game: Rovers" and "Rovers - Game" are both Rovers.
    private static func strippedOfMatchLabel(_ side: String) -> String {
        side
            .replacingOccurrences(of: labelPattern, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s*[:\-–—|]\s*(league |cup )?(match|game|fixture|friendly)$"#, with: "",
                                  options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: CharacterSet(charactersIn: " :-–—|,;#*\"'"))
    }

    private static func venueMark(in title: String) -> Fixture.Venue? {
        if title.range(of: #"[\(\[]\s*(h|home)\s*[\)\]]|\bhome\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return .home }
        if title.range(of: #"[\(\[]\s*(a|away)\s*[\)\]]|\baway\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return .away }
        return nil
    }

    private static func isOwn(_ side: String, _ teamNames: [String]) -> Bool {
        let key = normalized(strippedOfMatchLabel(side))
        return teamNames.map(normalized).contains { own in
            guard !own.isEmpty, !key.isEmpty else { return false }
            return " \(key) ".contains(" \(own) ") || (key.count >= 4 && " \(own) ".contains(" \(key) "))
        }
    }

    // MARK: Words

    private static let versusPattern = #"\s+(vs?\.?|versus|mot|gegen|contre|contra|kontra|tegen)\s+"#
    private static let atPattern = #"\s+(@|at)\s+"#
    private static let labelPattern = #"^\s*(soccer|football|futsal|league|cup|home|away)?\s*(match|game|fixture|friendly|scrimmage|kamp|spiel|partido|wedstrijd)(\s*day)?\s*\d*\s*([:\-–—|]\s*|$)"#

    private static let matchWords = ["match", "game", "fixture", "friendly", "scrimmage", "semifinal", "quarterfinal",
                                     "kamp", "spiel", "partido", "wedstrijd"]
    private static let trainingWords = ["practice", "training", "trening", "træning", "tryout", "tryouts", "session", "camp", "clinic"]
    private static let canceledWords = ["canceled", "cancelled", "postponed", "aflyst", "avlyst", "abgesagt"]
    /// Calendars hold other people's games too.
    private static let otherActivityWords = ["basketball", "baseball", "softball", "hockey", "tennis", "volleyball", "lacrosse", "rugby",
                                             "cricket", "golf", "chess", "poker", "trivia", "video", "board", "night", "party",
                                             "meeting", "dinner", "lunch", "breakfast", "coffee", "deposition", "hearing"]
    private static let genericSides: Set<String> = ["", "game", "match", "soccer", "football", "futsal", "friendly", "league", "cup",
                                                    "home", "away", "fixture", "scrimmage", "league game", "league match", "cup match",
                                                    "cup game", "soccer game", "soccer match", "football match", "tbd", "tba", "opponent", "bye"]

    private static func cleaned(_ title: String) -> String {
        let plain = String(title.unicodeScalars.filter { !$0.properties.isEmojiPresentation && $0.value != 0xFE0F })
        return plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
            .map { $0.isLetter || $0.isNumber ? String($0) : " " }.joined()
            .split(separator: " ").joined(separator: " ")
    }

    private static func containsWord(_ title: String, _ words: [String]) -> Bool {
        let padded = " \(normalized(title)) "
        return words.contains { padded.contains(" \(normalized($0)) ") }
    }

    private static func split(_ title: String, by pattern: String) -> (String, String)? {
        // "vs Rovers" has nothing on the left; a leading space lets the same pattern find it.
        let padded = " " + title
        guard let range = padded.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let right = padded[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !right.isEmpty else { return nil }
        return (padded[..<range.lowerBound].trimmingCharacters(in: .whitespaces), right)
    }

    private static func firstLine(_ text: String?) -> String? {
        let line = text?.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? nil : line
    }
}

// MARK: - Matching fixtures to places and recordings

public extension Fixture {
    /// The known field this fixture is played on: the nearest within 400 m, else one whose name
    /// the event's location mentions.
    func field(among fields: [FieldModel]) -> FieldModel? {
        if let coordinate {
            let nearest = fields
                .map { ($0, haversineMeters(coordinate, $0.rectangle.center)) }
                .min { $0.1 < $1.1 }
            return nearest.flatMap { $0.1 <= 400 ? $0.0 : nil }
        }
        guard let location = location?.localizedLowercase else { return nil }
        return fields
            .filter { $0.name.count >= 4 && location.contains($0.name.localizedLowercase) }
            .max { $0.name.count < $1.name.count }
    }
}

public enum FixtureMatcher {
    /// The fixture a recording belongs to, if one plainly overlaps it. Kickoffs slip and calendar
    /// times are often the meeting time, so the fixture counts from 45 minutes early to an hour late.
    public static func fixture(forMatchFrom start: Date, to end: Date, at coordinate: Coordinate2D? = nil,
                               among fixtures: [Fixture]) -> Fixture? {
        guard end > start else { return nil }
        let length = end.timeIntervalSince(start)
        let candidates = fixtures.compactMap { fixture -> (fixture: Fixture, overlap: TimeInterval, gap: TimeInterval)? in
            if let coordinate, let place = fixture.coordinate, haversineMeters(coordinate, place) > 5_000 { return nil }
            let from = max(start, fixture.start.addingTimeInterval(-45 * 60))
            let until = min(end, fixture.end.addingTimeInterval(60 * 60))
            let overlap = until.timeIntervalSince(from)
            guard overlap >= min(20 * 60, length / 2) else { return nil }
            return (fixture, overlap, abs(fixture.start.timeIntervalSince(start)))
        }
        // Back-to-back tournament games can overlap a recording equally well; the nearest kickoff wins.
        return candidates.min { $0.gap < $1.gap }?.fixture
    }
}
