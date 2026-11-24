import Foundation

// MARK: - Who played how much

/// Minutes each player was on the pitch in one team match, worked out from everyone's events.
public struct TeamMatchMinutes: Codable, Equatable, Sendable {
    public let kickoff: Date
    public let lengthMinutes: Double
    public let minutesByPlayer: [String: Double]
    /// Goals players logged as their own; nobody with none.
    public let goalsByPlayer: [String: Int]

    public init(kickoff: Date, lengthMinutes: Double, minutesByPlayer: [String: Double], goalsByPlayer: [String: Int] = [:]) {
        self.kickoff = kickoff
        self.lengthMinutes = lengthMinutes
        self.minutesByPlayer = minutesByPlayer
        self.goalsByPlayer = goalsByPlayer
    }
}

public enum TeamMinutes {
    /// Every player's watch records its own match, so kickoffs within two hours are one team match.
    /// Newest first. Recordings with no usable length are left out, not counted as zero.
    public static func matches(from events: [TeamEvent]) -> [TeamMatchMinutes] {
        let recordings = Dictionary(grouping: events) { "\($0.matchUUID)|\($0.playerName)" }
            .values.compactMap(recording)
            .sorted { $0.start < $1.start }

        var groups: [[Recording]] = []
        for recording in recordings {
            if let kickoff = groups.last?.first?.start, recording.start.timeIntervalSince(kickoff) < 2 * 3600 {
                groups[groups.count - 1].append(recording)
            } else {
                groups.append([recording])
            }
        }
        return groups.reversed().map { group in
            TeamMatchMinutes(
                kickoff: group[0].start,
                lengthMinutes: group.map(\.lengthMinutes).max() ?? 0,
                minutesByPlayer: Dictionary(group.map { ($0.player, $0.playedMinutes) }, uniquingKeysWith: max),
                goalsByPlayer: Dictionary(group.filter { $0.goals > 0 }.map { ($0.player, $0.goals) }, uniquingKeysWith: max))
        }
    }

    private struct Recording {
        let player: String
        let start: Date
        /// Playing time available: breaks between halves don't count.
        let lengthMinutes: Double
        let playedMinutes: Double
        let goals: Int
    }

    private static func recording(_ events: [TeamEvent]) -> Recording? {
        let ordered = events.sorted { $0.date < $1.date }
        guard let first = ordered.first, let last = ordered.last else { return nil }
        let start = ordered.first { $0.kind == .matchStart }?.date ?? first.date
        let end = ordered.last { $0.kind == .matchEnd }?.date ?? last.date
        // A match somebody forgot to stop says nothing about minutes.
        guard end.timeIntervalSince(start) >= 5 * 60, end.timeIntervalSince(start) <= 4 * 3600 else { return nil }

        // Started on the bench if the first substitution is a sub in with no break before it.
        let firstSubstitution = ordered.first { $0.kind == .subIn || $0.kind == .subOut }
        var isBenched = firstSubstitution?.kind == .subIn
            && !ordered.contains { $0.kind == .periodEnd && $0.date <= firstSubstitution!.date }
        var isInPlay = true
        var played: TimeInterval = 0
        var available: TimeInterval = 0
        var clock = start
        for event in ordered where event.date >= start && event.date <= end {
            let elapsed = event.date.timeIntervalSince(clock)
            if isInPlay { available += elapsed }
            if isInPlay && !isBenched { played += elapsed }
            clock = event.date
            switch event.kind {
            case .subOut: isBenched = true
            case .subIn: isBenched = false
            case .periodEnd: isInPlay = false
            case .periodStart: isInPlay = true
            default: break
            }
        }
        let remaining = end.timeIntervalSince(clock)
        if isInPlay { available += remaining }
        if isInPlay && !isBenched { played += remaining }
        return Recording(player: first.playerName, start: start, lengthMinutes: available / 60, playedMinutes: played / 60,
                         goals: ordered.filter { $0.kind == .goalMine }.count)
    }
}

/// A player's share of recent team matches, in words.
public struct RecentLoad: Equatable, Sendable {
    public enum Level: Sendable { case none, light, shared, heavy }

    public let matchesPlayed: Int
    public let matchesAvailable: Int
    public let minutes: Double
    /// Minutes per match, oldest first; nil where the player recorded nothing.
    public let perMatch: [Double?]
    /// The same, as a share of each match.
    public let shares: [Double?]
    public let level: Level

    /// `matches` newest first; only the first `count` are considered.
    public init(player: String, matches: [TeamMatchMinutes], count: Int = 5) {
        let recent = Array(matches.prefix(count))
        let played = recent.map { $0.minutesByPlayer[player] }
        perMatch = played.reversed()
        shares = zip(recent, played).map { match, minutes in
            minutes.map { match.lengthMinutes > 0 ? min(1, $0 / match.lengthMinutes) : 0 }
        }.reversed()
        matchesAvailable = recent.count
        matchesPlayed = played.compactMap { $0 }.filter { $0 > 0 }.count
        minutes = played.compactMap { $0 }.reduce(0, +)
        let available = recent.map(\.lengthMinutes).reduce(0, +)
        let share = available > 0 ? minutes / available : 0
        level = matchesPlayed == 0 ? .none : share >= 0.8 ? .heavy : share >= 0.4 ? .shared : .light
    }

    public var summary: String {
        guard matchesAvailable > 0 else { return "No recent matches" }
        switch level {
        // "Didn't play" and "didn't wear a watch" look the same from here, so claim neither.
        case .none: return "Nothing recorded lately"
        case .heavy: return "Nearly every minute"
        case .shared: return "Regular minutes"
        case .light: return matchesPlayed == 1 && matchesAvailable > 2 ? "Only one match lately" : "Short spells"
        }
    }
}

// MARK: - Invites

/// What one teammate sends another: a link that opens the join screen, in a message that works
/// wherever the link doesn't.
public struct TeamInvite: Hashable, Identifiable, Sendable {
    /// Nothing but joining goes by this scheme, so nothing else can be opened from outside the app.
    public static let scheme = "matchtracker-join"

    public let code: String
    public let name: String?
    public let captain: String?
    /// What the team plays in, as a `KitColors` id.
    public let kit: String?
    public var id: String { code }

    public init(code: String, name: String?, captain: String? = nil, kit: String? = nil) {
        self.code = code
        self.name = name
        self.captain = captain
        self.kit = kit
    }

    /// Nil for a code typed by hand, long ago, that no link can carry.
    public var link: URL? {
        guard Self.isCode(code) else { return nil }
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = code
        let items = [("team", name), ("captain", captain), ("kit", kit)].compactMap { key, value in
            value.map { URLQueryItem(name: key, value: $0) }
        }
        if !items.isEmpty { components.queryItems = items }
        return components.url
    }

    public var message: String {
        let opening = "Join \(name ?? "my team") on MatchTracker.\(captain.map { " \($0) is the captain." } ?? "")"
        guard let link else { return "\(opening)\nChoose Join a Team in the Team tab and enter this team code: \(code)" }
        return """
        \(opening)
        \(link.absoluteString)
        If the link doesn't open, choose Join a Team in the Team tab and paste this whole message.
        Team code: \(code)
        """
    }

    public init?(link: URL) {
        guard link.scheme?.lowercased() == Self.scheme, let host = link.host(), Self.isCode(host) else { return nil }
        let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems ?? []
        // Anyone can write a link, so what it calls things is kept short and on one line.
        func text(_ key: String) -> String? {
            guard let value = items.first(where: { $0.name == key })?.value else { return nil }
            let line = value.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return line.isEmpty ? nil : String(line.prefix(60))
        }
        self.init(code: host.uppercased(), name: text("team"), captain: text("captain"), kit: text("kit").flatMap(KitColors.init)?.id)
    }

    /// Accepts a bare code, a link, or a pasted invite message.
    public init?(pasted text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "\(Self.scheme)://\\S+", options: [.regularExpression, .caseInsensitive]),
           let link = URL(string: String(trimmed[range])), let invite = TeamInvite(link: link) {
            self = invite
        } else if let range = trimmed.range(of: #"(?<=code:)\s*[A-Za-z0-9][A-Za-z0-9-]{2,23}"#, options: [.regularExpression, .caseInsensitive]) {
            let sentName = trimmed.range(of: #"(?<=^Join ).+?(?= on MatchTracker)"#, options: .regularExpression)
                .map { String(trimmed[$0]) }
            self.init(code: trimmed[range].trimmingCharacters(in: .whitespaces).uppercased(),
                      name: sentName == "my team" ? nil : sentName)
        } else if Self.isCode(trimmed) {
            self.init(code: trimmed.uppercased(), name: nil)
        } else {
            return nil
        }
    }

    private static func isCode(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{2,23}$"#, options: .regularExpression) != nil
    }

    /// Six characters with nothing that can be misheard across a pitch.
    public static func newCode() -> String {
        String((0..<6).compactMap { _ in "ABCDEFGHJKMNPQRSTUVWXYZ23456789".randomElement() })
    }
}

// MARK: - Formations

public enum FormationShape {
    /// "4-3-3" from how far up the pitch players stand (0 our goal line, 1 theirs), the deepest
    /// being the goalkeeper. Nil with fewer than six outfield players.
    public static func name(depths: [Double]) -> String? {
        let outfield = Array(depths.sorted().dropFirst())
        guard outfield.count >= 6 else { return nil }
        // Lines are separated by the widest gaps between neighbors.
        let lineBreaks = outfield.indices.dropFirst()
            .filter { outfield[$0] - outfield[$0 - 1] >= 0.08 }
            .sorted { outfield[$0] - outfield[$0 - 1] > outfield[$1] - outfield[$1 - 1] }
            .prefix(3)
            .sorted()
        guard !lineBreaks.isEmpty else { return nil }
        let bounds = [0] + lineBreaks + [outfield.count]
        return zip(bounds.dropFirst(), bounds).map { "\($0 - $1)" }.joined(separator: "-")
    }

    /// Where a player stands, in plain words: `x` runs up the pitch, `y` left (0) to right (1).
    public static func role(x: Double, y: Double) -> String {
        if x < 0.14 && abs(y - 0.5) < 0.2 { return "Goalkeeper" }
        let side = y < 0.3 ? "Left" : y > 0.7 ? "Right" : nil
        switch x {
        case ..<0.36: return side.map { "\($0) back" } ?? "Center back"
        case ..<0.64: return side.map { "\($0) midfielder" } ?? "Central midfielder"
        default: return side.map { "\($0) winger" } ?? "Striker"
        }
    }

    /// A 4-3-3 to start from when there's nothing better, goalkeeper first.
    public static let startingPoints: [(x: Double, y: Double)] = [
        (0.06, 0.5),
        (0.26, 0.14), (0.22, 0.38), (0.22, 0.62), (0.26, 0.86),
        (0.48, 0.24), (0.44, 0.5), (0.48, 0.76),
        (0.74, 0.18), (0.8, 0.5), (0.74, 0.82)
    ]
}
