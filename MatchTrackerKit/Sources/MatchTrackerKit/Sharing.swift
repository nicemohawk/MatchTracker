import Foundation

// MARK: - Shared app-integration constants & helpers
//
// Small pieces of glue that both the iOS and watch targets need to agree on. Centralizing them
// in the Kit keeps the app group id, JSON coder configuration and duration formatting from
// drifting between targets.

/// The per-device shared-storage app group. Single source of truth for both targets.
public enum AppGroup {
    public static let identifier = "group.com.nicemohawk.MatchTracker"
}

/// The running app's marketing version and build, e.g. "1.0 (7)".
///
/// Shown on both apps' own screens, and reported watch → phone: a build number that doesn't match
/// what was just installed is the one-glance answer to "did this actually land?", and the
/// phone→watch install hop fails silently often enough to need one.
public enum AppVersion {
    public static var current: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// Canonical JSON coders for MatchTracker's on-disk and over-the-wire value types. ISO-8601
/// dates match the backend contract and the WatchConnectivity payloads.
public enum MatchTrackerJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Shared human-readable formatting used across both apps.
public enum MatchTrackerFormat {
    /// Formats a duration as `H:MM:SS`, dropping the hours field (`M:SS`) when under an hour.
    public static func hoursMinutesSeconds(_ duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
                         : String(format: "%d:%02d", minutes, seconds)
    }
}
