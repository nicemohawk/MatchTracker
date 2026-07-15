//
//  AppGroupStorage.swift
//  MatchTracker
//

import Foundation
import MatchTrackerKit

/// Shared app-group locations and lightweight persistence used across the watch app.
///
/// The app group container is the single source of truth for the offline field database
/// (via `FieldStore`), the in-progress match record (crash safety), finished match records,
/// and the small pieces of team/player metadata mirrored from the phone.
enum AppGroupStorage {
    static let identifier = MatchTrackerKit.AppGroup.identifier

    /// App-group container directory. Falls back to the app's own documents directory when the
    /// group container is unavailable (e.g. previews / unit hosts) so nothing crashes.
    static var containerURL: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return url
        }
        #if DEBUG
        MatchLog.error("App group \(identifier) unavailable on watch — falling back to Documents. Field DB / match records won't be shared with the phone. Check the app group is enabled on the watch App ID and provisioning profile.", category: "appgroup")
        #endif
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var inProgressMatchURL: URL {
        containerURL.appendingPathComponent("inProgressMatch.json")
    }

    static var finishedMatchesDirectory: URL {
        containerURL.appendingPathComponent("matches", isDirectory: true)
    }

    static var defaults: UserDefaults {
        if let defaults = UserDefaults(suiteName: identifier) {
            return defaults
        }
        #if DEBUG
        MatchLog.error("UserDefaults(suiteName: \(identifier)) is nil on watch — falling back to .standard; team/player metadata won't match the phone.", category: "appgroup")
        #endif
        return .standard
    }

    enum DefaultsKey {
        static let teamCode = "teamCode"
        static let playerName = "playerName"
    }

    static var teamCode: String? {
        get { defaults.string(forKey: DefaultsKey.teamCode) }
        set { defaults.set(newValue, forKey: DefaultsKey.teamCode) }
    }

    static var playerName: String? {
        get { defaults.string(forKey: DefaultsKey.playerName) }
        set { defaults.set(newValue, forKey: DefaultsKey.playerName) }
    }

    /// A single shared field store bound to the app-group container. Loaded once on first use.
    static let fieldStore: FieldStore = {
        let store = FieldStore(directory: containerURL)
        try? store.load()
        return store
    }()

    // MARK: - Match record persistence

    /// Overwrites the crash-safe in-progress record after every event.
    static func persistInProgress(_ record: MatchRecord) {
        guard let data = try? MatchTrackerJSON.encoder().encode(record) else { return }
        try? data.write(to: inProgressMatchURL, options: .atomic)
    }

    /// Reads a previously persisted in-progress record (used during session recovery).
    static func loadInProgress() -> MatchRecord? {
        guard let data = try? Data(contentsOf: inProgressMatchURL) else { return nil }
        return try? MatchTrackerJSON.decoder().decode(MatchRecord.self, from: data)
    }

    static func clearInProgress() {
        try? FileManager.default.removeItem(at: inProgressMatchURL)
    }

    /// Writes the final record for a finished match, keyed by workout UUID.
    @discardableResult
    static func persistFinished(_ record: MatchRecord) -> URL? {
        let directory = finishedMatchesDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(record.id.uuidString).json")
        guard let data = try? MatchTrackerJSON.encoder().encode(record) else { return nil }
        try? data.write(to: url, options: .atomic)
        return url
    }
}
