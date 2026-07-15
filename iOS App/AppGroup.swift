// AppGroup.swift
// MatchTracker

import Foundation
import MatchTrackerKit

/// Shared app-group storage locations used by the phone app and (mirrored) the watch.
enum AppGroup {
    static let identifier = MatchTrackerKit.AppGroup.identifier

    /// Root shared container. Falls back to Application Support if the app group is
    /// unavailable (e.g. running without provisioning) so the app still functions.
    static var containerURL: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return url
        }
        // The app group is unavailable at runtime (entitlement not granted by the signing profile,
        // or unsigned CI build). We fall back to Application Support so the app keeps working, but
        // this means phone/watch/widget data silently diverges — shout about it in DEBUG so it's
        // never mistaken for the real shared container.
        #if DEBUG
        MatchLog.error("App group \(identifier) unavailable — falling back to Application Support. Shared phone/watch data will diverge. Check the app group is enabled on the App ID and in the provisioning profile.", category: "appgroup")
        #endif
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MatchTracker", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    /// Directory the Kit `FieldStore` reads/writes `fields.json` in.
    static var fieldsDirectory: URL { containerURL }

    /// Directory holding received `MatchRecord` JSON files, keyed by workout UUID.
    static var matchesDirectory: URL {
        let url = containerURL.appendingPathComponent("matches", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func matchRecordURL(for id: UUID) -> URL {
        matchesDirectory.appendingPathComponent("\(id.uuidString).json")
    }
}
