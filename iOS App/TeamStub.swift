// TeamStub.swift
// MatchTracker

#if DEBUG
import Foundation
import MatchTrackerKit

/// Made-up team data for screenshots and UI tests: `-TeamStub full|new|quiet|error|live`,
/// `solo` (only you have played), `pair` (you and one teammate), `offline` (no signal, but something
/// saved from before) or `removed` (the team has turned you away).
@MainActor
final class TeamStub {
    static let current: TeamStub? = UserDefaults.standard.string(forKey: "TeamStub").flatMap { TeamStub(rawValue: $0) }

    private enum Scenario: String { case full, new, quiet, error, live, solo, pair, offline, removed }
    private let scenario: Scenario

    private init?(rawValue: String) {
        guard let scenario = Scenario(rawValue: rawValue) else { return nil }
        self.scenario = scenario
    }

    private var names: [String] {
        switch scenario {
        case .solo: return ["Ben Lachman"]
        case .pair: return ["Maya Ortiz", "Ben Lachman"]
        default: return Self.squad
        }
    }

    private static let squad = ["Maya Ortiz", "Ben Lachman", "Sam Whitfield", "Ana Kowalczyk", "Jordan Okafor", "Priya Raman", "Lou Bergström",
                         "Theo Nakamura", "Chris Adeyemi", "Dana Fitzgerald-Moore", "Eli Sandoval", "Noor Haddad", "Gus Pereira"]

    private func respond() async throws {
        try? await Task.sleep(for: .milliseconds(150))
        if scenario == .error || scenario == .offline { throw URLError(.notConnectedToInternet) }
        if scenario == .removed { throw APIError.httpStatus(403) }
    }

    /// Puts something from before on this device for `offline`, and nothing for the rest.
    func prepareCache(code: String) {
        TeamCache.remove(code)
        guard scenario == .offline else { return }
        TeamCache(season: makeStats(code: code, isWeek: false), lastMatch: TeamMinutes.matches(from: makeEvents()).first).save(code)
    }

    func stats(code: String, since: Date?) async throws -> TeamStats {
        try await respond()
        guard scenario != .new else { return TeamStats(teamCode: code, players: []) }
        let isWeek = since.map { $0 > Date().addingTimeInterval(-8 * 86_400) } ?? false
        if isWeek && scenario == .quiet { return TeamStats(teamCode: code, players: []) }
        return makeStats(code: code, isWeek: isWeek)
    }

    private func makeStats(code: String, isWeek: Bool) -> TeamStats {
        let matches = isWeek ? 2.0 : 9.0
        let players = names.enumerated().compactMap { index, name -> TeamStats.Player? in
            if isWeek && index > 8 { return nil }
            let share = 1 - Double(index) * 0.06
            return TeamStats.Player(
                name: name, matchesPlayed: max(1, Int(matches * share)),
                totalDistanceMeters: matches * 8_900 * share + Double(index * 137 % 400),
                averageWorkrateScore: 60 * share, goals: [3, 1, 2, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0][index] * (isWeek ? 1 : 3),
                assists: [0, 2, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0][index], minutesPlayed: matches * 88 * share,
                sprints: index == 7 ? nil : Int(matches * 19 * share))
        }
        return TeamStats(teamCode: code, teamName: "Red Dragons", players: players)
    }

    func formation() async throws -> TeamFormation? {
        try await respond()
        guard scenario == .full || scenario == .live else { return nil }
        return TeamFormation(name: "4-3-3", confidence: 0.72, slots: zip(names, FormationShape.startingPoints).map { name, point in
            TeamFormation.Slot(playerName: name, x: point.x + 0.02, y: point.y, role: FormationShape.role(x: point.x, y: point.y))
        })
    }

    func benchmark(cohort: BenchmarkCohort) async throws -> CohortBenchmark? {
        try await respond()
        guard scenario == .full, cohort != .position else { return nil }
        return CohortBenchmark(cohort: cohort == .everyone ? "Everyone" : "30–39", sampleSize: 1240, percentiles: .init(
            workrate: 78, distancePerMatchMeters: 64, sprintDistanceMeters: 52, highSpeedRunningMeters: 71, topSpeedMetersPerSecond: 45))
    }

    func livePlayers() async throws -> [LivePlayerStatus] {
        try await respond()
        guard scenario == .live else { return [] }
        return zip(names, FormationShape.startingPoints).enumerated().map { index, player in
            LivePlayerStatus(playerName: player.0, updatedAt: Date().addingTimeInterval(index == 9 ? -140 : -3),
                             x: index >= 10 ? nil : min(0.95, player.1.x + 0.1), y: index >= 10 ? nil : player.1.y,
                             heartRate: index == 5 ? nil : Double(142 + index * 4), distanceMeters: 3_100 + Double(index * 260),
                             onPitch: index < 10, stale: index == 9)
        }
    }

    func events() async throws -> [TeamEvent] {
        try await respond()
        return scenario == .new ? [] : makeEvents()
    }

    private func makeEvents() -> [TeamEvent] {
        var events: [TeamEvent] = []
        for match in 0..<6 {
            let kickoff = Date().addingTimeInterval(Double(match) * -7 * 86_400 - (scenario == .live ? 1.2 : 26) * 3600)
            for (index, name) in names.enumerated() where (index + match) % 6 != 5 && index != 12 {
                let recording = Self.id(1000 + match * 100 + index)
                func add(_ kind: MatchEventKind, _ minute: Double, note: String? = nil) {
                    events.append(TeamEvent(id: Self.id(100_000 + match * 1000 + index * 30 + events.count), playerName: name, matchUUID: recording,
                                            kindRawValue: kind.rawValue, date: kickoff.addingTimeInterval(minute * 60), note: note,
                                            coachLabel: kind == .flag && index == 3 ? "Good line" : nil))
                }
                add(.matchStart, 0)
                if index > 8 { add(.subIn, 60 + Double(index)) }
                if index == 0 { add(.goalMine, 11); add(.goalMine, 84, note: "Top corner") }
                if index == 1 { add(.assist, 84) }
                if index == 3 { add(.flag, 38) }
                if index == 4 { add(.yellowCard, 71) }
                if index > 5 && index <= 8 { add(.subOut, 55 + Double(index)) }
                add(.matchEnd, 92)
            }
        }
        return events
    }

    private static func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }
}
#endif
