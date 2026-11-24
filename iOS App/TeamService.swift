// TeamService.swift
// MatchTracker

import Foundation
import MatchTrackerKit

/// Everything the team screens ask of the backend.
@MainActor
enum TeamService {
    static func stats(code: String, since: Date? = nil) async throws -> TeamStats {
        #if DEBUG
        if let stub = TeamStub.current { return try await stub.stats(code: code, since: since) }
        #endif
        do {
            return try await client().teamStats(code: code, since: since)
        } catch APIError.httpStatus(404) {
            // A code nobody has uploaded under yet is a new team, not a failure.
            return TeamStats(teamCode: code, players: [])
        }
    }

    /// Nil when there isn't enough to go on yet.
    static func formation(code: String) async throws -> TeamFormation? {
        #if DEBUG
        if let stub = TeamStub.current { return try await stub.formation() }
        #endif
        do {
            return try await client().formation(code: code)
        } catch APIError.httpStatus(404) {
            return nil
        }
    }

    /// Nil when the group is too small to compare against.
    static func benchmark(cohort: BenchmarkCohort) async throws -> CohortBenchmark? {
        #if DEBUG
        if let stub = TeamStub.current { return try await stub.benchmark(cohort: cohort) }
        #endif
        do {
            return try await client().benchmark(cohort: cohort)
        } catch APIError.httpStatus(404) {
            return nil
        }
    }

    static func comments(match: UUID) async throws -> [MatchComment] {
        #if DEBUG
        if let stub = TeamStub.current { return try await stub.comments(match: match) }
        #endif
        do {
            return try await client().comments(match: match)
        } catch APIError.httpStatus(404) {
            return []
        }
    }

    static func post(_ comment: MatchComment) async throws {
        #if DEBUG
        if let stub = TeamStub.current { return try await stub.post(comment) }
        #endif
        try await client().postComment(comment, match: comment.matchUUID)
    }

    static func livePlayers(code: String) async throws -> [LivePlayerStatus] {
        #if DEBUG
        if let stub = TeamStub.current { return try await stub.livePlayers() }
        #endif
        do {
            return try await client().liveTeam(code: code)
        } catch APIError.httpStatus(404) {
            return []
        }
    }

    static func events(code: String, sinceHours: Int) async throws -> [TeamEvent] {
        #if DEBUG
        if let stub = TeamStub.current { return try await stub.events() }
        #endif
        do {
            return try await client().teamEvents(code: code, sinceHours: sinceHours)
        } catch APIError.httpStatus(404) {
            return []
        }
    }

    static func annotate(_ event: TeamEvent, note: String) async throws {
        #if DEBUG
        if TeamStub.current != nil { return }
        #endif
        try await client().annotateEvent(id: event.id, matchUUID: event.matchUUID, label: note)
    }

    // MARK: Client

    private struct NotReady: Error {}

    private static func client() throws -> APIClient {
        guard let key = KeychainHelper.string(forKey: "apiKey"), !key.isEmpty else { throw NotReady() }
        return APIClient(baseURL: SettingsStore.shared.baseURL, apiKey: key, deviceID: deviceID)
    }

    /// Written by `UploadService` on first launch.
    private static var deviceID: UUID {
        AppGroup.defaults.string(forKey: "deviceID").flatMap(UUID.init) ?? UUID()
    }

    /// What went wrong, for a person.
    static func explain(_ error: Error) -> String {
        switch error {
        case let error as URLError where [.notConnectedToInternet, .dataNotAllowed, .networkConnectionLost].contains(error.code):
            return "You're offline. Connect and try again."
        case is NotReady:
            return "Team features are still setting up on this device. Try again in a moment."
        case APIError.httpStatus(401), APIError.httpStatus(403):
            return "This team isn't sharing with you. Check the team code with a teammate."
        default:
            return "The team service isn't answering. Your own matches are safe."
        }
    }

    /// Whether the server turned this down because it's part of the Team plan.
    static func needsPlan(_ error: Error) -> Bool {
        guard case APIError.httpStatus(let status) = error else { return false }
        return status == 402 || status == 403
    }
}
