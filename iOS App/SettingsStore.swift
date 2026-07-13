// SettingsStore.swift
// MatchTracker

import Foundation
import Combine
import MatchTrackerKit

/// User-facing settings persisted to the app-group `UserDefaults` so the watch can read them too.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults: UserDefaults

    private enum Key {
        static let playerName = "playerName"
        static let teamCode = "teamCode"
        static let serverURLOverride = "serverURLOverride"
        static let teamMemberships = "teamMemberships"
        static let consentGuardianName = "consentGuardianName"
        static let consentAcknowledgedAt = "consentAcknowledgedAt"
    }

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: AppGroup.identifier) ?? .standard
    }

    @Published var didChange = 0

    var playerName: String {
        get { defaults.string(forKey: Key.playerName) ?? "" }
        set { defaults.set(newValue, forKey: Key.playerName); bump() }
    }

    var teamCode: String {
        get { defaults.string(forKey: Key.teamCode) ?? "" }
        set { defaults.set(newValue, forKey: Key.teamCode); bump() }
    }

    var serverURLOverride: String {
        get { defaults.string(forKey: Key.serverURLOverride) ?? "" }
        set { defaults.set(newValue, forKey: Key.serverURLOverride); bump() }
    }

    /// Effective backend base URL: override if valid, otherwise the Kit default.
    var baseURL: URL {
        if let url = URL(string: serverURLOverride), url.scheme != nil { return url }
        return APIClient.defaultBaseURL
    }

    // MARK: - Team memberships (multi-team)

    /// Every team this player belongs to. `teamCode` remains the default team for uploads and
    /// the watch. Migrates the legacy single code into a membership on first read.
    var teamMemberships: [TeamMembership] {
        get {
            if let data = defaults.data(forKey: Key.teamMemberships),
               let memberships = try? MatchTrackerJSON.decoder().decode([TeamMembership].self, from: data) {
                return memberships
            }
            // Legacy migration: a bare teamCode becomes the sole membership.
            guard !teamCode.isEmpty else { return [] }
            return [TeamMembership(code: teamCode, name: nil, displayInitialsOnly: false)]
        }
        set {
            if let data = try? MatchTrackerJSON.encoder().encode(newValue) {
                defaults.set(data, forKey: Key.teamMemberships)
            }
            // Keep the legacy default-team code in sync for the watch + uploads.
            if let first = newValue.first, !newValue.contains(where: { $0.code == teamCode }) {
                defaults.set(first.code, forKey: Key.teamCode)
            }
            if newValue.isEmpty {
                defaults.set("", forKey: Key.teamCode)
            }
            bump()
        }
    }

    // MARK: - Guardian consent (minors privacy)

    var consentGuardianName: String? {
        get { defaults.string(forKey: Key.consentGuardianName) }
        set { defaults.set(newValue, forKey: Key.consentGuardianName); bump() }
    }

    var consentAcknowledgedAt: Date? {
        get { defaults.object(forKey: Key.consentAcknowledgedAt) as? Date }
        set { defaults.set(newValue, forKey: Key.consentAcknowledgedAt); bump() }
    }

    private func bump() {
        objectWillChange.send()
        didChange &+= 1
    }
}
