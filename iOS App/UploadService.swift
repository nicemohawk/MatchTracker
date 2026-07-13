// UploadService.swift
// MatchTracker

import Foundation
import CloudKit
import MatchTrackerKit

/// Uploads matches and fields to the backend via the Kit `APIClient`.
/// API key bootstrap ports the legacy `AppDelegate` flow: fetch the CloudKit public
/// record "default" field "apiKey", caching it in the Keychain.
@MainActor
final class UploadService: ObservableObject {
    @Published private(set) var status: String?
    @Published private(set) var isUploading = false
    /// Uploads waiting in the persistent retry queue (surfaced in Settings).
    @Published private(set) var pendingUploadCount = 0

    /// Persistent retry queue; created once an API key exists (it needs a live client).
    private var queue: UploadQueue?

    private let settings: SettingsStore
    private let fields: FieldsModel
    private unowned let matches: MatchStore

    private var apiKey: String?
    private let deviceID: UUID

    private let defaults: UserDefaults
    private let uploadedKey = "uploadedMatchIDs"
    private let keychainKey = "apiKey"

    init(settings: SettingsStore, fields: FieldsModel, matches: MatchStore) {
        self.settings = settings
        self.fields = fields
        self.matches = matches
        self.defaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard
        self.deviceID = Self.resolveDeviceID(defaults: defaults)
        self.apiKey = KeychainHelper.string(forKey: keychainKey)
    }

    // MARK: - API key

    /// Fetch the API key from CloudKit (legacy behavior), caching to Keychain; falls back to
    /// the cached Keychain value on any failure. Best-effort — never throws to the caller.
    func bootstrapAPIKey() async {
        do {
            let database = CKContainer.default().publicCloudDatabase
            let record = try await database.record(for: CKRecord.ID(recordName: "default"))
            if let key = record["apiKey"] as? String {
                apiKey = key
                KeychainHelper.set(key, forKey: keychainKey)
            }
        } catch {
            if apiKey == nil {
                apiKey = KeychainHelper.string(forKey: keychainKey)
            }
        }
    }

    private var client: APIClient? {
        guard let apiKey, !apiKey.isEmpty else { return nil }
        return APIClient(baseURL: settings.baseURL, apiKey: apiKey, deviceID: deviceID)
    }

    // MARK: - Persistent queue

    private func makeQueueIfNeeded() {
        guard queue == nil, let client else { return }
        queue = UploadQueue(directory: AppGroup.containerURL, client: client)
        pendingUploadCount = queue?.pending.count ?? 0
    }

    /// Attempt everything due in the retry queue; safe to call anytime.
    func flushQueue() async {
        makeQueueIfNeeded()
        guard let queue else { return }
        let remaining = await queue.flush()
        pendingUploadCount = remaining
        if remaining > 0 {
            status = "\(remaining) upload\(remaining == 1 ? "" : "s") pending retry"
        }
    }

    /// Relay one live update to the backend, best-effort (sideline dashboards).
    func relayLive(_ update: LiveMatchUpdate) {
        guard let client,
              let teamCode = settings.teamCode.isEmpty ? nil : settings.teamCode else { return }
        Task {
            do {
                try await client.postLive(update, matchUUID: deviceScopedLiveMatchID, teamCode: teamCode)
            } catch {
                MatchLog.error("Live relay failed: \(error.localizedDescription)", category: "live")
            }
        }
    }

    /// The live endpoint keys rows by device; a stable per-session UUID groups this match's
    /// updates until the finished record replaces it.
    private lazy var deviceScopedLiveMatchID = UUID()

    // MARK: - Matches

    /// Upload matches not yet sent. Called after new records arrive.
    func autoUpload(_ summaries: [MatchSummary]) {
        let pending = summaries.filter { !uploadedIDs.contains($0.id) }
        guard !pending.isEmpty else { return }
        Task { await upload(summaries: pending, markUploaded: true) }
    }

    /// Manual re-upload of a single match (ignores the uploaded set).
    func reupload(_ summary: MatchSummary) async {
        await upload(summaries: [summary], markUploaded: true)
    }

    /// Upload every known match.
    func uploadAll() async {
        await upload(summaries: matches.matches, markUploaded: true)
        await uploadFields()
    }

    private func upload(summaries: [MatchSummary], markUploaded: Bool) async {
        guard let client else {
            status = "No API key yet"
            return
        }
        guard !summaries.isEmpty else { return }
        isUploading = true
        defer { isUploading = false }

        var payloads: [MatchPayload] = []
        var sentIDs: [UUID] = []
        for summary in summaries {
            let detail = matches.detailModel(for: summary)
            await detail.load()
            payloads.append(buildPayload(summary: summary, detail: detail))
            sentIDs.append(summary.id)
        }

        guard !payloads.isEmpty else { status = "Nothing to upload"; return }

        // Route through the persistent queue: an immediate flush sends them now when the network
        // cooperates, and anything that fails survives relaunches and retries with backoff.
        makeQueueIfNeeded()
        if let queue {
            do {
                for payload in payloads {
                    try queue.enqueue(match: payload)
                }
                if markUploaded { markIDs(sentIDs) }
                let remaining = await queue.flush()
                pendingUploadCount = remaining
                status = remaining == 0
                    ? "Uploaded \(payloads.count) match\(payloads.count == 1 ? "" : "es")"
                    : "\(remaining) upload\(remaining == 1 ? "" : "s") queued for retry"
            } catch {
                status = "Upload failed: \(error.localizedDescription)"
            }
        } else {
            // No API key yet: fall back to a direct attempt (legacy behavior).
            do {
                try await client.post(matches: payloads)
                if markUploaded { markIDs(sentIDs) }
                status = "Uploaded \(payloads.count) match\(payloads.count == 1 ? "" : "es")"
            } catch {
                status = "Upload failed: \(error.localizedDescription)"
            }
        }
    }

    private func buildPayload(summary: MatchSummary, detail: MatchDetailModel) -> MatchPayload {
        // Record-only matches (no HK workout / GPS route) still upload, with empty coordinates.
        let coordinates = detail.track.map { [$0.coordinate.latitude, $0.coordinate.longitude] }
        let report = detail.analytics?.workrate ?? WorkrateReport()
        let position = detail.analytics?.position
        let teamCode = summary.record?.teamCode ?? (settings.teamCode.isEmpty ? nil : settings.teamCode)
        let playerName = settings.playerName.isEmpty ? nil : settings.playerName
        return MatchPayload(
            uuid: summary.id,
            recordedAt: summary.startDate,
            coordinates: coordinates,
            events: summary.record?.events ?? [],
            fieldUUID: summary.record?.fieldID,
            teamCode: teamCode,
            playerName: playerName,
            sportID: summary.record?.sportID,
            stats: MatchStats(report: report, position: position)
        )
    }

    // MARK: - Privacy passthroughs

    func postConsent(guardianName: String) async throws {
        guard let client else { throw TeamStatsError.noAPIKey }
        try await client.postConsent(guardianName: guardianName)
    }

    func requestServerDeletion() async throws {
        guard let client else { throw TeamStatsError.noAPIKey }
        try await client.requestDeletion()
    }

    // MARK: - Team stats

    enum TeamStatsError: LocalizedError {
        case noAPIKey
        var errorDescription: String? { "No API key available yet." }
    }

    func fetchTeamStats(code: String) async throws -> TeamStats {
        guard let client else { throw TeamStatsError.noAPIKey }
        return try await client.teamStats(code: code)
    }

    func fetchFormation(code: String) async throws -> TeamFormation {
        guard let client else { throw TeamStatsError.noAPIKey }
        return try await client.formation(code: code)
    }

    func fetchComments(match: UUID) async throws -> [MatchComment] {
        guard let client else { throw TeamStatsError.noAPIKey }
        return try await client.comments(match: match)
    }

    func postComment(_ comment: MatchComment, match: UUID) async throws {
        guard let client else { throw TeamStatsError.noAPIKey }
        try await client.postComment(comment, match: match)
    }

    func fetchLiveTeam(code: String) async throws -> [LivePlayerStatus] {
        guard let client else { throw TeamStatsError.noAPIKey }
        return try await client.liveTeam(code: code)
    }

    // MARK: - Fields

    func uploadFields() async {
        guard let client else { status = "No API key yet"; return }
        let toUpload = fields.fields
        guard !toUpload.isEmpty else { return }
        makeQueueIfNeeded()
        if let queue {
            try? queue.enqueue(fields: toUpload)
            pendingUploadCount = await queue.flush()
        } else {
            do {
                try await client.post(fields: toUpload)
            } catch {
                status = "Field upload failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Uploaded set

    private var uploadedIDs: Set<UUID> {
        let strings = defaults.stringArray(forKey: uploadedKey) ?? []
        return Set(strings.compactMap(UUID.init))
    }

    private func markIDs(_ ids: [UUID]) {
        var set = uploadedIDs
        ids.forEach { set.insert($0) }
        defaults.set(set.map(\.uuidString), forKey: uploadedKey)
    }

    private static func resolveDeviceID(defaults: UserDefaults) -> UUID {
        if let string = defaults.string(forKey: "deviceID"), let id = UUID(uuidString: string) {
            return id
        }
        let id = UUID()
        defaults.set(id.uuidString, forKey: "deviceID")
        return id
    }
}
