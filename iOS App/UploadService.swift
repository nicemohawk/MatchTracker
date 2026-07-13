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

        do {
            try await client.post(matches: payloads)
            if markUploaded { markIDs(sentIDs) }
            status = "Uploaded \(payloads.count) match\(payloads.count == 1 ? "" : "es")"
        } catch {
            status = "Upload failed: \(error.localizedDescription)"
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
            stats: MatchStats(report: report, position: position)
        )
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

    // MARK: - Fields

    func uploadFields() async {
        guard let client else { status = "No API key yet"; return }
        let toUpload = fields.fields
        guard !toUpload.isEmpty else { return }
        do {
            try await client.post(fields: toUpload)
        } catch {
            status = "Field upload failed: \(error.localizedDescription)"
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
