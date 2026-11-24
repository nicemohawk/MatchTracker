import Foundation

/// Everywhere a widget, Live Activity, control or shortcut can send someone. Both apps handle the
/// `matchtracker://` form.
public enum MatchTrackerLink: Hashable, Sendable {
    /// Start a match on the watch.
    case start
    case live
    case season
    case latestMatch
    case match(UUID)
    /// The match that kicked off around this moment. A Live Activity ends before the phone knows
    /// the finished match's identity, so kickoff is what it links by.
    case matchStarting(Date)
    /// Saying how that match went.
    case review(startingAt: Date)
    /// Joining a team. The only one another app can open; see `TeamInvite.scheme`.
    case join(TeamInvite)

    public static let scheme = "matchtracker"

    public var url: URL {
        let path: String
        switch self {
        case .start: path = "start"
        case .live: path = "live"
        case .season: path = "season"
        case .latestMatch: path = "match/latest"
        case .match(let id): path = "match/\(id.uuidString)"
        case .matchStarting(let date): path = "match/at/\(Int(date.timeIntervalSince1970))"
        case .review(let date): path = "match/at/\(Int(date.timeIntervalSince1970))/review"
        case .join(let invite): return invite.link
        }
        return URL(string: "\(Self.scheme)://\(path)")!
    }

    public init?(_ url: URL) {
        if let invite = TeamInvite(link: url) {
            self = .join(invite)
            return
        }
        guard url.scheme == Self.scheme else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        switch (url.host(), path.count) {
        case ("start", 0): self = .start
        case ("live", 0): self = .live
        case ("season", 0): self = .season
        case ("match", 1) where path[0] == "latest": self = .latestMatch
        case ("match", 1):
            guard let id = UUID(uuidString: path[0]) else { return nil }
            self = .match(id)
        case ("match", 2) where path[0] == "at":
            guard let seconds = TimeInterval(path[1]) else { return nil }
            self = .matchStarting(Date(timeIntervalSince1970: seconds))
        case ("match", 3) where path[0] == "at" && path[2] == "review":
            guard let seconds = TimeInterval(path[1]) else { return nil }
            self = .review(startingAt: Date(timeIntervalSince1970: seconds))
        default: return nil
        }
    }
}
