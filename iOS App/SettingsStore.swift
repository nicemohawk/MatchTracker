// SettingsStore.swift
// MatchTracker

import Foundation
import Combine
import MatchTrackerKit

/// Which units the player sees. `automatic` follows the region.
enum UnitsPreference: String, CaseIterable, Identifiable {
    case automatic, imperial, metric

    var id: String { rawValue }

    var system: UnitSystem? {
        switch self {
        case .automatic: return nil
        case .imperial: return .imperial
        case .metric: return .metric
        }
    }
}

/// User-facing settings persisted to the app-group `UserDefaults` so the watch can read them too.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults: UserDefaults

    private enum Key {
        static let playerName = "playerName"
        static let teamCode = "teamCode"
        static let serverURLOverride = "serverURLOverride"
        static let teamMemberships = "teamMemberships"
        static let viewedTeam = "viewedTeam"
        static let confirmedTeams = "confirmedTeams"
        static let leftTeams = "leftTeams"
        static let consentGuardianName = "consentGuardianName"
        static let consentAcknowledgedAt = "consentAcknowledgedAt"
        static let contributeDetectedFields = "contributeDetectedFields"
        static let asksAfterMatches = "asksAfterMatches"
        static let playHabits = "playHabits"
        static let units = "units"
    }

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: AppGroup.identifier) ?? .standard
        UnitSystem.override = units.system
    }

    @Published var didChange = 0

    var playerName: String {
        get { defaults.string(forKey: Key.playerName) ?? "" }
        set { defaults.set(newValue, forKey: Key.playerName); bump() }
    }

    /// The team new matches are shared with; empty when they're shared with nobody.
    var teamCode: String {
        get { defaults.string(forKey: Key.teamCode) ?? "" }
        set { defaults.set(newValue, forKey: Key.teamCode); bump() }
    }

    var serverURLOverride: String {
        get { defaults.string(forKey: Key.serverURLOverride) ?? "" }
        set { defaults.set(newValue, forKey: Key.serverURLOverride); bump() }
    }

    /// Miles and yards, or kilometers and meters. Applied app-wide through `UnitSystem.override`.
    var units: UnitsPreference {
        get { defaults.string(forKey: Key.units).flatMap(UnitsPreference.init) ?? .automatic }
        set {
            defaults.set(newValue.rawValue, forKey: Key.units)
            UnitSystem.override = newValue.system
            bump()
        }
    }

    /// Effective backend base URL: override if valid, otherwise the Kit default.
    var baseURL: URL {
        if let url = URL(string: serverURLOverride), url.scheme != nil { return url }
        return APIClient.defaultBaseURL
    }

    /// How each kind of match is played, as far as the player has said.
    var playHabits: PlayHabits {
        get { defaults.data(forKey: Key.playHabits).flatMap { try? JSONDecoder().decode(PlayHabits.self, from: $0) } ?? PlayHabits() }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.playHabits)
            bump()
        }
    }

    /// Whether to ask how a match ended once it arrives. On until turned off.
    var asksAfterMatches: Bool {
        get { defaults.object(forKey: Key.asksAfterMatches) == nil || defaults.bool(forKey: Key.asksAfterMatches) }
        set { defaults.set(newValue, forKey: Key.asksAfterMatches); bump() }
    }

    /// Whether nearby pitches detected on-device from satellite imagery are contributed to the
    /// community field database as low-confidence seeds. Default on; the seed uploads never touch
    /// the personal field list.
    var contributeDetectedFields: Bool {
        get {
            guard defaults.object(forKey: Key.contributeDetectedFields) != nil else { return true }
            return defaults.bool(forKey: Key.contributeDetectedFields)
        }
        set { defaults.set(newValue, forKey: Key.contributeDetectedFields); bump() }
    }

    // MARK: - Team memberships (multi-team)

    /// Every team this player belongs to. A code on its own, from versions where one could be typed
    /// into Settings, counts as one too.
    var teamMemberships: [TeamMembership] {
        get {
            let saved = defaults.data(forKey: Key.teamMemberships)
                .flatMap { try? MatchTrackerJSON.decoder().decode([TeamMembership].self, from: $0) } ?? []
            guard !teamCode.isEmpty, !saved.contains(where: { $0.code == teamCode }) else { return saved }
            return saved + [TeamMembership(code: teamCode)]
        }
        set {
            if let data = try? MatchTrackerJSON.encoder().encode(newValue) {
                defaults.set(data, forKey: Key.teamMemberships)
            }
            // Keep the legacy default-team code in sync for the watch + uploads.
            if let first = newValue.first, !teamCode.isEmpty, !newValue.contains(where: { $0.code == teamCode }) {
                defaults.set(first.code, forKey: Key.teamCode)
            }
            if newValue.isEmpty {
                defaults.set("", forKey: Key.teamCode)
            }
            bump()
        }
    }

    /// The team on the Team tab. Looking at one team doesn't change who new matches go to.
    var viewedTeam: String {
        get {
            let codes = teamMemberships.map(\.code)
            return [defaults.string(forKey: Key.viewedTeam), teamCode].compactMap { $0 }.first(where: codes.contains) ?? codes.first ?? ""
        }
        set { defaults.set(newValue, forKey: Key.viewedTeam); bump() }
    }

    /// Teams the server knows this device is on, and teams it has yet to hear this device left.
    var confirmedTeams: [String] {
        get { defaults.stringArray(forKey: Key.confirmedTeams) ?? [] }
        set { defaults.set(newValue, forKey: Key.confirmedTeams) }
    }

    var leftTeams: [String] {
        get { defaults.stringArray(forKey: Key.leftTeams) ?? [] }
        set { defaults.set(newValue, forKey: Key.leftTeams) }
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
