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

    private func bump() {
        objectWillChange.send()
        didChange &+= 1
    }
}
