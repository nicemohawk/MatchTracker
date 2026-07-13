import Foundation
#if canImport(os)
import os
#endif

// MARK: - Diagnostics

/// Thin logging facade over `os.Logger` (with a `print` fallback where `os` is unavailable, e.g.
/// Linux CI).
///
/// - Important: NEVER pass raw GPS coordinates or health values (heart rate, calories, positions)
///   into these messages. Logs may be persisted to disk and read by others; match tracks and
///   biometrics stay out of them by contract.
public enum MatchLog {
    /// Shared subsystem for all MatchTracker logs.
    public static let subsystem = "com.nicemohawk.MatchTracker"

    public static func info(_ message: String, category: String) {
        #if canImport(os)
        logger(for: category).info("\(message, privacy: .public)")
        #else
        print("[\(subsystem)] [\(category)] INFO: \(message)")
        #endif
    }

    public static func error(_ message: String, category: String) {
        #if canImport(os)
        logger(for: category).error("\(message, privacy: .public)")
        #else
        print("[\(subsystem)] [\(category)] ERROR: \(message)")
        #endif
    }

    #if canImport(os)
    // `os.Logger` is cheap but not free to construct; cache one per category behind a lock so the
    // facade is safe to call from any thread (recorder, upload queue, UI).
    private static let lock = NSLock()
    private nonisolated(unsafe) static var loggers: [String: Logger] = [:]

    private static func logger(for category: String) -> Logger {
        lock.lock()
        defer { lock.unlock() }
        if let existing = loggers[category] { return existing }
        let logger = Logger(subsystem: subsystem, category: category)
        loggers[category] = logger
        return logger
    }
    #endif
}
